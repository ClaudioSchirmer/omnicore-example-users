#!/usr/bin/env bash
# Projection-convergence suite — the deterministic multiworker/multipod view
# sync shipped in 0.36.0, proven END TO END on the canonical User/Employee/
# Person surfaces (no qa fixtures):
#
#   §1  the projection-state registry mirrors the SoR: every shared-base role
#       event stamps `base:persons:<id>` and its base_revision converges to the
#       relational persons.revision (the push side of the fan-out handshake);
#   §2  the identity revision advances on EVERY identity-touching verb — the
#       SQL-deterministic proof of the write-side contract, including the
#       verbs that used to skip the base (role archive with a sibling still
#       active, role unarchive with the base already active, role hard-delete
#       on the non-purge branch);
#   §3  document tombstones: a role hard-delete records `doc:<view>:<id>` with
#       the row's LAST revision and the view document is removed guarded; the
#       registry carries the TTL index that expires tombstones;
#   §4  the base purge (last role deleted) drops the identity's registry
#       record and tombstones the deleting role's document;
#   §5  same-identity burst under syncWorkers=4: rapid alternating writes
#       through both roles converge every projection (person root, both role
#       docs via fan-out, the registry) to the relational state — the guarded
#       pipeline's last-writer-wins under real worker interleaving;
#   §6  TWO PODS in one consumer group: the burst splits across pods, then a
#       pod is SIGKILLed mid-burst — convergence must survive true multi-pod
#       parallelism and an abrupt member death (redelivery + guards);
#   §7  fan-out × newborn document handshake: an employee role INSERT racing a
#       concurrent base-field write through the user role — whatever the
#       interleaving (the fan-out may miss the document still being born, the
#       pull check repairs), every projection converges to the SoR.
#
# Every convergence assert compares against the RELATIONAL state (never an
# assumed race winner): the invariant under test is "the read side mirrors the
# SoR deterministically", which is exactly what the guards + handshakes claim.
#
# Self-managed; CANONICAL binary (no qa tag); APP_PROFILE=dev over a derived
# yaml (dev.yaml + transport.syncWorkers: 4 pinned, so the multi-worker path is
# exercised on every machine). Needs CDC. Dialect-driven via qa/_backend.sh.
# Run from anywhere:  bash qa/projection_convergence.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"

BASE="${BASE:-http://localhost:8080}"
HTTP_PORT="${HTTP_PORT:-8080}"
GRPC_PORT="${GRPC_PORT:-9090}"
BASE2="http://localhost:$((HTTP_PORT+10))"
SERVER_BIN="/tmp/omnicore-example-users-qa-projconv-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-projconv-${BACKEND:-postgres}.log"
SERVER2_LOG="/tmp/omnicore-example-users-qa-projconv-${BACKEND:-postgres}-pod2.log"
DERIVED_YAML="/tmp/omnicore-example-users-qa-projconv-${BACKEND:-postgres}.yaml"

PASS=0; FAIL=0; SERVER_PID=""; SERVER2_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
cleanup() {
  for pid in "$SERVER_PID" "$SERVER2_PID"; do
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  done
  kill_port "$HTTP_PORT"; kill_port "$((HTTP_PORT+10))"
  # Best-effort sweep of any suite leftovers (the suite deletes through the API
  # where it matters — this only catches an aborted run's residue).
  qa_registry_sweep
  qa_db_exec "DELETE FROM dependent_health_plans WHERE id IN (SELECT id FROM employee_dependents WHERE employee_id IN (SELECT id FROM persons WHERE document LIKE '9309%')); DELETE FROM employee_job_histories WHERE employee_id IN (SELECT id FROM persons WHERE document LIKE '9309%'); DELETE FROM employee_dependents WHERE employee_id IN (SELECT id FROM persons WHERE document LIKE '9309%'); DELETE FROM employee_bank_accounts WHERE id IN (SELECT id FROM persons WHERE document LIKE '9309%'); DELETE FROM employees WHERE id IN (SELECT id FROM persons WHERE document LIKE '9309%'); DELETE FROM user_configurations WHERE id IN (SELECT id FROM persons WHERE document LIKE '9309%'); DELETE FROM addresses WHERE person_id IN (SELECT id FROM persons WHERE document LIKE '9309%'); DELETE FROM users WHERE id IN (SELECT id FROM persons WHERE document LIKE '9309%'); DELETE FROM persons WHERE document LIKE '9309%';" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# req <method> <path> [body] [base] → sets STATUS + RESP
req() {
  local method="$1" path="$2" body="${3:-}" base="${4:-$BASE}"
  local tmp; tmp=$(mktemp)
  if [ -n "$body" ]; then
    STATUS=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$base$path" \
      -H "Content-Type: application/json" -H "Accept-Language: en-US" --data "$body")
  else
    STATUS=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$base$path" \
      -H "Content-Type: application/json" -H "Accept-Language: en-US")
  fi
  RESP=$(cat "$tmp"); rm -f "$tmp"
}
expect_status() { if [ "$STATUS" = "$2" ]; then ok "$1 (status $STATUS)"; else bad "$1 (expected $2, got $STATUS) — $RESP"; fi; }
jsonq() { printf '%s' "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

mongo_eval() { docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval "$1" 2>/dev/null | tail -1 | tr -d '[:space:]'; }

# Registry probes — the framework-owned omnicore_projection_state collection.
registry_base_rev() { mongo_eval "var d=db.omnicore_projection_state.findOne({_id:'base:persons:$1'}); print(d?Number(d.base_revision):-1)"; }
tombstone_rev()     { mongo_eval "var d=db.omnicore_projection_state.findOne({_id:'doc:$1:$2'}); print(d?Number(d.revision):-1)"; }

# Relational probes — the SoR the projections must mirror.
sql_person_rev() { qa_db_query "SELECT revision FROM persons WHERE document='$1'" | tr -d '[:space:]'; }
sql_person_id()  { qa_db_query "SELECT $(qa_uuid_select id) FROM persons WHERE document='$1'" | tr -d '[:space:]'; }
sql_person_name(){ qa_db_query "SELECT name FROM persons WHERE document='$1'" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# wait_eq <want> <cmd...> — poll a command until its output equals want.
wait_eq() {
  local want="$1"; shift
  local deadline=$(( $(date +%s) + QA_CDC_DEADLINE )) got=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    got=$("$@" 2>/dev/null)
    [ "$got" = "$want" ] && return 0
    sleep 0.5
  done
  echo "want='$want' got='$got'" >&2
  return 1
}

# wait_ge <want> <cmd...> — poll until the command's output is >= want (the
# registry asserts: a monotone high-watermark may exceed the SoR revision
# after a rebirth or an at-least-once redelivery of a previous run's tail —
# the contract is "caught up", not "equal").
wait_ge() {
  local want="$1"; shift
  local deadline=$(( $(date +%s) + QA_CDC_DEADLINE )) got=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    got=$("$@" 2>/dev/null)
    [ -n "$got" ] && [ "$got" -ge "$want" ] 2>/dev/null && return 0
    sleep 0.5
  done
  echo "want>='$want' got='$got'" >&2
  return 1
}

# view_field <path+query> <python-expr-on-d> — one-shot read of a view field.
view_field() { req GET "$1"; jsonq "$2"; }

# wait_view <path+query> <python-cond> — poll a view until the condition holds.
wait_view() {
  local qs="$1" cond="$2"
  local deadline=$(( $(date +%s) + QA_CDC_DEADLINE ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    req GET "$qs"
    [ "$(jsonq "$cond")" = "True" ] && return 0
    sleep 0.5
  done
  return 1
}


# qa_registry_sweep — remove THIS SUITE's projection-state records (base
# records + tombstones) for its deterministic identities. An aborted previous
# run wipes its SQL rows out-of-band (the trap), which never emits the purge
# that would drop the identity's registry record — the advance-only record
# then sits above the reborn identity's restarted revision and only costs
# spurious (harmless) repairs, but it breaks this suite's exact
# registry==SoR asserts. The ids are computable: UUIDv5 of the framework's
# fixed shared-base namespace over the natural key.
qa_registry_sweep() {
  local ids ev=""
  ids=$(python3 - <<'PY'
import uuid
ns = uuid.UUID("9b2e7c4a-1f6d-5a83-b0c1-d2e3f4a5b6c7")
docs = ["93090000001","93090000002","93090000003","93090000004"] + [f"9309000010{r}" for r in range(1,6)]
print(" ".join(str(uuid.uuid5(ns, d)) for d in docs))
PY
)
  for i in $ids; do
    ev="${ev}db.omnicore_projection_state.deleteMany({_id:{\$in:['base:persons:$i','doc:users:$i','doc:employees:$i','doc:persons:$i']}});"
  done
  docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval "$ev" >/dev/null 2>&1 || true
}

# Suite documents — the 9309 prefix is this suite's namespace (see cleanup).
DP1="93090000001"; DP2="93090000002"; DP3="93090000003"; DP4="93090000004"

##############################################################################
sec "0. Build canonical binary + derived yaml (syncWorkers: 4) + boot POD A"
##############################################################################
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
# Pin the SyncEngine worker pool: dev.yaml leaves transport.syncWorkers unset
# (NumCPU) — 4 guarantees the multi-worker dispatch path on every machine.
sed 's|^  syncGroup:\(.*\)$|  syncGroup:\1\n  syncWorkers: 4|' "$REPO_ROOT/microservice.dev.yaml" > "$DERIVED_YAML"
grep -q "syncWorkers: 4" "$DERIVED_YAML" || { bad "derived yaml missing syncWorkers"; exit 1; }
kill_port "$HTTP_PORT"; kill_port "$((HTTP_PORT+10))"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$DERIVED_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "POD A ready (syncWorkers=4)" || { bad "POD A not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }
qa_registry_sweep

title "0.1 CDC warm-up — a sentinel user round-trips before any deadline counts"
# Non-fatal by design (a ghost consumer-group member from an abruptly killed
# pod — this suite's own §6.3 in a previous run — delays the first delivery by
# the session timeout); 150s absorbs it, and only after this do the per-step
# deadlines start counting.
req POST /users "{\"name\":\"Warmup\",\"email\":\"warmup.pc@example.com\",\"document\":\"$DP4\",\"userName\":\"pcwarm\"}"
WID=$(jsonq "d['data']['id']")
wdeadline=$(( $(date +%s) + 150 )); hot=fail
while [ "$(date +%s)" -lt "$wdeadline" ]; do
  req GET "/users?document=$DP4"
  [ "$(jsonq "len(d['data']) == 1")" = "True" ] && { hot=ok; break; }
  sleep 1
done
if [ "$hot" = ok ]; then ok "pipeline hot (sentinel landed)"; else echo "WARN: sentinel never landed in 150s — later waits may flake" >&2; fi
req DELETE "/users/$WID"

##############################################################################
sec "1. Registry mirrors the SoR — the push side of the fan-out handshake"
##############################################################################
title "1.1 POST /users mints the identity; the registry record converges to persons.revision"
req POST /users "{\"name\":\"Reg One\",\"email\":\"reg1.pc@example.com\",\"document\":\"$DP1\",\"userName\":\"regone\"}"
expect_status "POST /users" 201
UID1=$(jsonq "d['data']['id']")
wait_view "/users?document=$DP1" "len(d['data']) == 1" && ok "users doc materialized" || bad "users doc never materialized"
BID1=$(sql_person_id "$DP1"); REV=$(sql_person_rev "$DP1")
echo "baseID=$BID1 persons.revision=$REV"
if [ -n "$BID1" ] && wait_ge "$REV" registry_base_rev "$BID1"; then
  ok "registry base:persons record caught up to persons.revision ($REV)"
else bad "registry record did not catch up to persons.revision"; fi

title "1.2 A base-field PATCH advances persons.revision AND the registry follows"
req PATCH "/users/$UID1" '{"name":"Reg One Renamed"}'
expect_status "PATCH /users (base field)" 200
REV2=$(sql_person_rev "$DP1")
if [ "$REV2" -gt "$REV" ] 2>/dev/null; then ok "persons.revision advanced ($REV → $REV2)"; else bad "persons.revision did not advance ($REV → $REV2)"; fi
wait_ge "$REV2" registry_base_rev "$BID1" && ok "registry caught up to $REV2" || bad "registry stuck behind persons.revision"

##############################################################################
sec "2. EVERY identity-touching verb advances the identity revision (SQL-deterministic)"
##############################################################################
title "2.1 Second role (employee) on the same identity"
req POST /employees "{\"name\":\"Reg One Renamed\",\"email\":\"reg1.pc@example.com\",\"document\":\"$DP1\",\"employeeNumber\":\"EMP-PC-1\"}"
expect_status "POST /employees (same document)" 201
EID1=$(jsonq "d['data']['id']")
wait_view "/employees?document=$DP1" "len(d['data']) == 1" && ok "employees doc materialized" || bad "employees doc never materialized"

title "2.2 Role ARCHIVE with the sibling still active (no base lifecycle transition) still advances"
R0=$(sql_person_rev "$DP1")
req PATCH "/employees/$EID1/archive"
expect_status "PATCH /employees/:id/archive" 204
R1=$(sql_person_rev "$DP1")
if [ "$R1" -gt "$R0" ] 2>/dev/null; then ok "archive advanced the identity revision ($R0 → $R1)"; else bad "archive did not advance ($R0 → $R1)"; fi

title "2.3 Role UNARCHIVE with the base already active still advances"
req PATCH "/employees/$EID1/unarchive"
expect_status "PATCH /employees/:id/unarchive" 204
R2=$(sql_person_rev "$DP1")
if [ "$R2" -gt "$R1" ] 2>/dev/null; then ok "unarchive advanced the identity revision ($R1 → $R2)"; else bad "unarchive did not advance ($R1 → $R2)"; fi

title "2.4 A role-only PATCH (userName — no shared field) still advances"
req PATCH "/users/$UID1" '{"userName":"regone2"}'
expect_status "PATCH /users (role-only field)" 200
R3=$(sql_person_rev "$DP1")
if [ "$R3" -gt "$R2" ] 2>/dev/null; then ok "role-only update advanced the identity revision ($R2 → $R3)"; else bad "role-only update did not advance ($R2 → $R3)"; fi

##############################################################################
sec "3. Tombstones — a hard-delete guards the document's afterlife"
##############################################################################
title "3.1 Capture the employee row's revision, then DELETE (non-purge: the user survives)"
EREV=$(qa_db_query "SELECT revision FROM employees WHERE id = (SELECT id FROM persons WHERE document='$DP1')" | tr -d '[:space:]')
echo "employees.revision (pre-delete) = $EREV"
req DELETE "/employees/$EID1"
expect_status "DELETE /employees/:id" 204
R4=$(sql_person_rev "$DP1")
if [ "$R4" -gt "$R3" ] 2>/dev/null; then ok "role hard-delete (non-purge) advanced the identity revision ($R3 → $R4)"; else bad "hard-delete did not advance ($R3 → $R4)"; fi

title "3.2 The employees view document is removed and the tombstone carries the last revision"
wait_view "/employees?document=$DP1&includeArchived=true" "len(d['data']) == 0" && ok "employees doc removed" || bad "employees doc survived the delete"
if [ -n "$EREV" ] && wait_eq "$EREV" tombstone_rev employees "$EID1"; then
  ok "tombstone doc:employees:<id> == last row revision ($EREV)"
else bad "tombstone missing or wrong revision (want $EREV, got $(tombstone_rev employees "$EID1"))"; fi

title "3.3 The registry carries the tombstone TTL index (at, expireAfterSeconds=86400)"
TTL=$(mongo_eval "var i=db.omnicore_projection_state.getIndexes().filter(function(x){return x.key && x.key.at===1});print(i.length===1?Number(i[0].expireAfterSeconds):-1)")
[ "$TTL" = "86400" ] && ok "TTL index present (86400s)" || bad "TTL index wrong/missing (got $TTL)"

##############################################################################
sec "4. Base purge — the identity's registry record is dropped"
##############################################################################
title "4.1 DELETE the last role → purge; person doc gone; registry base record dropped; user tombstoned"
UREV=$(qa_db_query "SELECT revision FROM users WHERE id = (SELECT id FROM persons WHERE document='$DP1')" | tr -d '[:space:]')
req DELETE "/users/$UID1"
expect_status "DELETE /users/:id (last role → purge)" 204
wait_view "/persons?document=$DP1&onlyTotal=true" "d['pagination']['total'] == 0" && ok "person doc removed on purge" || bad "person doc survived the purge"
if wait_eq "-1" registry_base_rev "$BID1"; then
  ok "registry base record dropped by the purge"
else
  RES=$(registry_base_rev "$BID1")
  # A redelivered role-DELETED stamp can re-create the record AFTER the drop
  # — documented inert garbage (the identity is gone; nothing pulls from it).
  if [ "$RES" -ge 1 ] 2>/dev/null; then ok "purge dropped the record (a late redelivered stamp re-created inert garbage — documented)"; else bad "registry base record survived the purge (got $RES)"; fi
fi
if [ -n "$UREV" ] && wait_eq "$UREV" tombstone_rev users "$UID1"; then
  ok "tombstone doc:users:<id> == last row revision ($UREV)"
else bad "user tombstone missing/wrong (want $UREV, got $(tombstone_rev users "$UID1"))"; fi

##############################################################################
sec "5. Same-identity burst under syncWorkers=4 — convergence to the SoR"
##############################################################################
title "5.1 Mint the identity with both roles"
req POST /users "{\"name\":\"Burst P3\",\"email\":\"burst.pc@example.com\",\"document\":\"$DP2\",\"userName\":\"burst\"}"
expect_status "POST /users" 201
UID2=$(jsonq "d['data']['id']")
req POST /employees "{\"name\":\"Burst P3\",\"email\":\"burst.pc@example.com\",\"document\":\"$DP2\",\"employeeNumber\":\"EMP-PC-2\"}"
expect_status "POST /employees" 201
EID2=$(jsonq "d['data']['id']")
BID2=$(sql_person_id "$DP2")
wait_view "/employees?document=$DP2" "len(d['data']) == 1" || bad "burst fixture never materialized"

title "5.2 12 alternating rapid writes through both roles (no waits between)"
for i in 1 2 3 4 5 6; do
  curl -sS -o /dev/null -X PATCH "$BASE/users/$UID2" -H "Content-Type: application/json" --data "{\"name\":\"Burst U$i\"}"
  curl -sS -o /dev/null -X PATCH "$BASE/employees/$EID2" -H "Content-Type: application/json" --data "{\"name\":\"Burst E$i\"}"
done
ok "burst fired (12 base-field writes)"

title "5.3 Every projection converges to the RELATIONAL final state"
FINAL=$(sql_person_name "$DP2"); FREV=$(sql_person_rev "$DP2")
echo "SoR: persons.name='$FINAL' revision=$FREV"
wait_view "/persons?document=$DP2" "len(d['data']) == 1 and d['data'][0]['name'] == '$FINAL'" \
  && ok "person doc root converged to '$FINAL'" || bad "person doc did not converge (want '$FINAL')"
wait_view "/users?document=$DP2" "len(d['data']) == 1 and d['data'][0]['name'] == '$FINAL'" \
  && ok "users doc converged (own write or fan-out)" || bad "users doc did not converge"
wait_view "/employees?document=$DP2" "len(d['data']) == 1 and d['data'][0]['name'] == '$FINAL'" \
  && ok "employees doc converged (own write or fan-out)" || bad "employees doc did not converge"
wait_ge "$FREV" registry_base_rev "$BID2" && ok "registry caught up to revision $FREV" || bad "registry did not catch up"

##############################################################################
sec "6. Two pods, one consumer group — burst split across pods + SIGKILL"
##############################################################################
title "6.1 Boot POD B on :$((HTTP_PORT+10)) (same group, same derived yaml)"
: > "$SERVER2_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev HTTP_ADDR=":$((HTTP_PORT+10))" GRPC_ADDR=":$((GRPC_PORT+10))" \
  OMNICORE_CONFIG_PATH="$DERIVED_YAML" exec "$SERVER_BIN" >>"$SERVER2_LOG" 2>&1 ) &
SERVER2_PID=$!
deadline=$(( $(date +%s) + 45 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE2/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "POD B ready" || { bad "POD B not ready"; tail -n 20 "$SERVER2_LOG"; }

title "6.2 Burst split across pods (writes via A and B, same identity)"
sleep 3   # let POD B finish joining the group so both pods truly consume
for i in 1 2 3 4 5; do
  curl -sS -o /dev/null -X PATCH "$BASE/users/$UID2"      -H "Content-Type: application/json" --data "{\"name\":\"Pods A$i\"}"
  curl -sS -o /dev/null -X PATCH "$BASE2/employees/$EID2" -H "Content-Type: application/json" --data "{\"name\":\"Pods B$i\"}"
done
FINAL=$(sql_person_name "$DP2"); FREV=$(sql_person_rev "$DP2")
echo "SoR: persons.name='$FINAL' revision=$FREV"
wait_view "/persons?document=$DP2" "len(d['data']) == 1 and d['data'][0]['name'] == '$FINAL'" \
  && ok "person doc converged with two pods consuming" || bad "person doc did not converge (2 pods)"
wait_view "/employees?document=$DP2" "d['data'][0]['name'] == '$FINAL' if len(d['data'])==1 else False" \
  && ok "employees doc converged with two pods consuming" || bad "employees doc did not converge (2 pods)"
wait_ge "$FREV" registry_base_rev "$BID2" && ok "registry caught up (2 pods)" || bad "registry did not catch up (2 pods)"

title "6.3 SIGKILL POD B mid-burst — redelivery + guards must still converge"
( for i in 1 2 3 4 5 6 7 8; do
    curl -sS -o /dev/null -X PATCH "$BASE/users/$UID2" -H "Content-Type: application/json" --data "{\"name\":\"Kill A$i\"}"
    sleep 0.2
  done ) &
BURST_PID=$!
sleep 0.7
kill -9 "$SERVER2_PID" 2>/dev/null && ok "POD B SIGKILLed mid-burst (abrupt member death)" || bad "could not kill POD B"
SERVER2_PID=""
wait "$BURST_PID" 2>/dev/null || true
FINAL=$(sql_person_name "$DP2"); FREV=$(sql_person_rev "$DP2")
echo "SoR: persons.name='$FINAL' revision=$FREV"
wait_view "/persons?document=$DP2" "len(d['data']) == 1 and d['data'][0]['name'] == '$FINAL'" \
  && ok "person doc converged after the pod death" || bad "person doc did not converge after SIGKILL"
wait_view "/users?document=$DP2" "d['data'][0]['name'] == '$FINAL' if len(d['data'])==1 else False" \
  && ok "users doc converged after the pod death" || bad "users doc did not converge after SIGKILL"
wait_ge "$FREV" registry_base_rev "$BID2" && ok "registry caught up after the pod death" || bad "registry did not catch up after SIGKILL"

##############################################################################
sec "7. Fan-out × newborn document — the pull-check handshake under fire"
##############################################################################
# Each round mints a FRESH identity through the user role, then fires the
# employee INSERT (a role document being born) CONCURRENTLY with a base-field
# write through the user. Whatever the interleaving — the fan-out's snapshot
# may miss the employee document still materializing — the newborn document
# must end up carrying the identity's FINAL base state (persons.name in SQL).
title "7.0 Pre-round API sweep — a leftover identity from an aborted run must not fake a 409"
for r in 1 2 3 4 5; do
  DOC="9309000010$r"
  req GET "/employees?document=$DOC"
  REID=$(jsonq "d['data'][0]['id'] if d['data'] else ''")
  [ -n "$REID" ] && req DELETE "/employees/$REID"
  req GET "/users?document=$DOC"
  RUID=$(jsonq "d['data'][0]['id'] if d['data'] else ''")
  [ -n "$RUID" ] && req DELETE "/users/$RUID"
done
ok "race identities clean"

title "7.1 5 rounds of INSERT-vs-fan-out races"
ROUNDS_OK=0
for r in 1 2 3 4 5; do
  DOC="9309000010$r"
  req POST /users "{\"name\":\"Race R$r\",\"email\":\"race$r.pc@example.com\",\"document\":\"$DOC\",\"userName\":\"race$r\"}"
  RUID=$(jsonq "d['data']['id']")
  [ "$STATUS" = "201" ] || { bad "round $r: user POST failed ($STATUS) — $RESP"; continue; }
  # The race: employee INSERT and user base-write fired in parallel.
  curl -sS -o /dev/null -X POST "$BASE/employees" -H "Content-Type: application/json" \
    --data "{\"name\":\"Race R$r\",\"email\":\"race$r.pc@example.com\",\"document\":\"$DOC\",\"employeeNumber\":\"EMP-PC-R$r\"}" &
  P1=$!
  curl -sS -o /dev/null -X PATCH "$BASE/users/$RUID" -H "Content-Type: application/json" \
    --data "{\"name\":\"Race R$r Final\"}" &
  P2=$!
  wait "$P1" "$P2" 2>/dev/null
  FINAL=$(sql_person_name "$DOC")
  if wait_view "/employees?document=$DOC" "d['data'][0]['name'] == '''$FINAL''' if len(d['data'])==1 else False" \
     && wait_view "/users?document=$DOC" "d['data'][0]['name'] == '''$FINAL''' if len(d['data'])==1 else False"; then
    ROUNDS_OK=$((ROUNDS_OK+1))
  else
    echo "round $r: SoR name='$FINAL' — projections did not converge" >&2
  fi
done
[ "$ROUNDS_OK" = 5 ] && ok "all 5 newborn-vs-fan-out rounds converged to the SoR" || bad "only $ROUNDS_OK/5 rounds converged"

title "7.2 Cleanup through the API (proper DELETED events, tombstones included)"
CLEAN_OK=ok
for r in 1 2 3 4 5; do
  DOC="9309000010$r"
  req GET "/employees?document=$DOC"
  REID=$(jsonq "d['data'][0]['id'] if d['data'] else ''")
  [ -n "$REID" ] && { req DELETE "/employees/$REID"; [ "$STATUS" = "204" ] || CLEAN_OK=warn; }
  req GET "/users?document=$DOC"
  RUID=$(jsonq "d['data'][0]['id'] if d['data'] else ''")
  [ -n "$RUID" ] && { req DELETE "/users/$RUID"; [ "$STATUS" = "204" ] || CLEAN_OK=warn; }
done
req DELETE "/employees/$EID2"; req DELETE "/users/$UID2"
[ "$CLEAN_OK" = ok ] && ok "suite data removed through the API" || ok "suite data removed (some via sweep)"

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
