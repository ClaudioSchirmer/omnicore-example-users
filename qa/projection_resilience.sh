#!/usr/bin/env bash
# Projection-resilience suite — the §10 runtime criteria of the projection
# integrity program (tasks/sync_fixes.md) that need a DEGRADED Mongo to be
# exercised for real, on the 3-node replica-set bench:
#
#   §1  failover durability: a projection write acknowledged (majority) before
#       a primary step-down is still present afterwards, and a write issued
#       DURING the election converges once a primary is back;
#   §2  the parking ledger exercised in runtime: a full quorum loss (2 of 3
#       nodes stopped) makes projection writes fail beyond the in-process
#       retry budget, the event is parked in omnicore_projection_failures
#       (visible via SQL — the relational control plane IS the dead-letter
#       store), and after quorum returns the ledger sweep replays it: the row
#       resolves and the document materializes with no manual action.
#
# The suite asserts OUTCOMES (the document converges, the ledger empties),
# never which mechanism won: on this bench the lanes connect with
# directConnection=true, so an election fails writes fast and events park
# quickly; a production replica-set URI would instead absorb a short election
# inside one bounded attempt. Both routes are the design working as specified.
#
# DISRUPTIVE by design: it steps down the shared bench's Mongo primary and
# stops 2 of its 3 nodes for a bounded window. It MUST run in run.sh's serial
# phase (never in a parallel wave), and its trap restores the replica set even
# on abort. Self-managed; CANONICAL binary (no qa tag); APP_PROFILE=dev.
# Needs CDC + docker. Dialect-driven via qa/_backend.sh.
# Run from anywhere:  bash qa/projection_resilience.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"

BASE="${BASE:-http://localhost:8080}"
HTTP_PORT="${HTTP_PORT:-8080}"
SERVER_BIN="/tmp/omnicore-example-users-qa-projres-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-projres-${BACKEND:-postgres}.log"

MONGO_NODE1="omnicore-qa-mongo"; MONGO_NODE2="omnicore-qa-mongo2"; MONGO_NODE3="omnicore-qa-mongo3"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }

# restore_quorum — idempotent: start the stopped nodes and wait for a primary.
# Called from the trap too, so an aborted run never leaves the bench degraded.
restore_quorum() {
  docker start "$MONGO_NODE2" "$MONGO_NODE3" >/dev/null 2>&1 || true
  local deadline=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(docker exec "$MONGO_NODE1" mongosh admin --quiet --eval 'print(db.hello().isWritablePrimary)' 2>/dev/null | tail -1)" = "true" ] && return 0
    sleep 2
  done
  return 1
}

cleanup() {
  restore_quorum || echo "WARN: replica set did not recover a primary in the trap" >&2
  [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null && { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
  kill_port "$HTTP_PORT"
  # Aborted-run residue: SQL rows out-of-band (never emits the delete event),
  # this suite's registry records, and any pending ledger rows still carrying
  # the suite's payloads (replaying one after the SQL rows are gone would
  # materialize a ghost document).
  qa_db_exec "DELETE FROM omnicore_projection_failures WHERE payload LIKE '%9409000%';" 2>/dev/null || true
  qa_db_exec "DELETE FROM user_configurations WHERE id IN (SELECT id FROM persons WHERE document LIKE '9409%'); DELETE FROM addresses WHERE person_id IN (SELECT id FROM persons WHERE document LIKE '9409%'); DELETE FROM users WHERE id IN (SELECT id FROM persons WHERE document LIKE '9409%'); DELETE FROM persons WHERE document LIKE '9409%';" 2>/dev/null || true
  qa_registry_sweep
}
trap cleanup EXIT INT TERM

req() {
  local method="$1" path="$2" body="${3:-}"
  local tmp; tmp=$(mktemp)
  if [ -n "$body" ]; then
    STATUS=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" \
      -H "Content-Type: application/json" -H "Accept-Language: en-US" --data "$body" 2>/dev/null || echo 000)
  else
    STATUS=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" \
      -H "Content-Type: application/json" -H "Accept-Language: en-US" 2>/dev/null || echo 000)
  fi
  RESP=$(cat "$tmp"); rm -f "$tmp"
}
expect_status() { if [ "$STATUS" = "$2" ]; then ok "$1 (status $STATUS)"; else bad "$1 (expected $2, got $STATUS) — $RESP"; fi; }
jsonq() { printf '%s' "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

# wait_status <path> <want> <seconds> — poll a GET until it answers want.
wait_status() {
  local path="$1" want="$2" secs="$3"
  local deadline=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    req GET "$path"
    [ "$STATUS" = "$want" ] && return 0
    sleep 1
  done
  return 1
}

# Ledger probes — the relational dead-letter store, queried through the lane's
# own SQL seam so the assertion is on the control plane itself.
ledger_pending()  { qa_db_query "SELECT COUNT(*) FROM omnicore_projection_failures WHERE aggregate_id='$1' AND resolved_at IS NULL" | tr -d '[:space:]'; }
ledger_resolved() { qa_db_query "SELECT COUNT(*) FROM omnicore_projection_failures WHERE aggregate_id='$1' AND resolved_at IS NOT NULL" | tr -d '[:space:]'; }

# wait_eq <want> <cmd...> — poll a command until its output equals want.
wait_eq() {
  local want="$1" secs="$2"; shift 2
  local deadline=$(( $(date +%s) + secs )) got=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    got=$("$@" 2>/dev/null)
    [ "$got" = "$want" ] && return 0
    sleep 1
  done
  echo "want='$want' got='$got'" >&2
  return 1
}

mongo_primary_node() {
  for n in "$MONGO_NODE1" "$MONGO_NODE2" "$MONGO_NODE3"; do
    [ "$(docker exec "$n" mongosh admin --quiet --eval 'print(db.hello().isWritablePrimary)' 2>/dev/null | tail -1)" = "true" ] && { echo "$n"; return 0; }
  done
  return 1
}

# qa_registry_sweep — this suite's projection-state records (see the
# convergence suite for the rationale; same fixed UUIDv5 namespace).
qa_registry_sweep() {
  local ids ev=""
  ids=$(python3 - <<'PY'
import uuid
ns = uuid.UUID("9b2e7c4a-1f6d-5a83-b0c1-d2e3f4a5b6c7")
print(" ".join(str(uuid.uuid5(ns, d)) for d in ["94090000001","94090000002","94090000003"]))
PY
)
  for i in $ids; do
    ev="${ev}db.omnicore_projection_state.deleteMany({_id:{\$in:['base:persons:$i','doc:users:$i','doc:persons:$i']}});"
  done
  docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval "$ev" >/dev/null 2>&1 || true
}

DP1="94090000001"; DP2="94090000002"; DP3="94090000003"

##############################################################################
sec "0. Preconditions + build + boot"
##############################################################################
title "0.1 The bench replica set has 3 members and a primary"
if [ "$(docker ps --format '{{.Names}}' | grep -cE "^(${MONGO_NODE1}|${MONGO_NODE2}|${MONGO_NODE3})$")" = "3" ] && [ -n "$(mongo_primary_node)" ]; then
  ok "replica set up (primary: $(mongo_primary_node))"
else
  bad "replica set not healthy — this suite requires the 3-node bench"; exit 1
fi

(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "$HTTP_PORT"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }

title "0.2 CDC warm-up — a sentinel round-trips before any deadline counts"
req POST /users "{\"name\":\"Resilience Warmup\",\"email\":\"warm.pr@example.com\",\"document\":\"$DP3\",\"userName\":\"prwarm\",\"ethnicity\":\"white\",\"userProfile\":1}"
WID=$(jsonq "d['data']['id']")
wdeadline=$(( $(date +%s) + 150 )); hot=fail
while [ "$(date +%s)" -lt "$wdeadline" ]; do
  req GET "/users?document=$DP3"
  [ "$(jsonq "len(d['data']) == 1")" = "True" ] && { hot=ok; break; }
  sleep 1
done
if [ "$hot" = ok ]; then ok "pipeline hot (sentinel landed)"; else echo "WARN: sentinel never landed in 150s — later waits may flake" >&2; fi
req DELETE "/users/$WID"

##############################################################################
sec "1. Failover durability — primary step-down"
##############################################################################
title "1.1 A majority-acked projection exists BEFORE the step-down"
req POST /users "{\"name\":\"Before Failover\",\"email\":\"before.pr@example.com\",\"document\":\"$DP1\",\"userName\":\"prbefore\",\"ethnicity\":\"white\",\"userProfile\":1}"
expect_status "POST /users (user A)" 201
UA=$(jsonq "d['data']['id']")
wait_status "/users/$UA" 200 "$QA_CDC_DEADLINE" && ok "user A materialized (majority-acked)" || bad "user A never materialized"

title "1.2 Step the primary down (15s freeze) and write user B during the disruption"
PRIMARY=$(mongo_primary_node)
docker exec "$PRIMARY" mongosh admin --quiet --eval 'try { rs.stepDown(15) } catch (e) { }' >/dev/null 2>&1 || true
ok "step-down issued on $PRIMARY"
req POST /users "{\"name\":\"During Failover\",\"email\":\"during.pr@example.com\",\"document\":\"$DP2\",\"userName\":\"prduring\",\"ethnicity\":\"white\",\"userProfile\":1}"
expect_status "POST /users (user B, during election — the SoR write is unaffected)" 201
UB=$(jsonq "d['data']['id']")

title "1.3 After the election: A survived (durability), B converged (retry or ledger replay)"
# B's window: election (<=15s) + retry budget + at worst one ledger sweep
# (60s interval). 150s covers the whole chain with slack.
wait_status "/users/$UA" 200 150 && ok "user A still present after the failover — the acked write survived" || bad "user A LOST across the failover"
wait_status "/users/$UB" 200 150 && ok "user B converged despite writing into the election window" || bad "user B never converged after the election"

title "1.4 No pending ledger rows remain for either user"
wait_eq 0 90 ledger_pending "$UA" && ok "no pending park for user A" || bad "user A left a pending ledger row"
wait_eq 0 90 ledger_pending "$UB" && ok "no pending park for user B" || bad "user B left a pending ledger row"

##############################################################################
sec "2. Quorum loss — the parking ledger exercised end to end"
##############################################################################
title "2.1 Stop 2 of 3 nodes: majority gone, primary steps down"
docker stop "$MONGO_NODE2" "$MONGO_NODE3" >/dev/null
deadline=$(( $(date +%s) + 60 )); degraded=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ -z "$(mongo_primary_node)" ] && { degraded=ok; break; }
  sleep 2
done
[ "$degraded" = ok ] && ok "no primary — writes beyond majority are impossible" || bad "primary survived a quorum loss (bench misconfigured?)"

title "2.2 PATCH user A while the read side cannot write — the SoR accepts it"
req PATCH "/users/$UA" '{"name":"Renamed During Outage"}'
expect_status "PATCH /users/A (during quorum loss)" 200

title "2.3 The event parks: omnicore_projection_failures gains a pending row (via SQL)"
# With no primary the driver BLOCKS the write (it does not fail fast, even
# over directConnection) — each attempt is cut by the engine's 30s per-attempt
# deadline, which is precisely the stall-protection this case exists to prove.
# Budget: 5 attempts x 30s + backoffs + CDC arrival ≈ 155s; 210s adds margin.
wait_eq 1 210 ledger_pending "$UA" && ok "event parked in the relational ledger" || bad "no pending ledger row appeared for user A"

title "2.4 Restore quorum"
restore_quorum && ok "replica set recovered a primary" || bad "replica set did not recover"

title "2.5 The sweep replays with no manual action: row resolves, document converges"
# The retry driver sweeps every 60s; allow two full intervals.
wait_eq 0 150 ledger_pending "$UA" && ok "pending row drained" || bad "ledger row still pending after quorum restore"
wait_eq 1 30 ledger_resolved "$UA" && ok "row marked resolved (audit trail kept)" || bad "no resolved ledger row for user A"
name_now() { req GET "/users/$UA"; jsonq "d['data']['name']"; }
wait_eq "Renamed During Outage" 60 name_now && ok "document carries the outage-window PATCH" || bad "document did not converge to the parked event's state"

title "2.6 The server log carries the structured failure trail"
if grep -q '"msg":"projection.retry"' "$SERVER_LOG" && grep -q '"msg":"projection.event.parked"' "$SERVER_LOG"; then
  ok "projection.retry + projection.event.parked present (observability contract)"
else
  bad "expected projection.retry and projection.event.parked in the server log"
fi
grep -q '"msg":"projection.parked_event.replayed"' "$SERVER_LOG" && ok "projection.parked_event.replayed present" || bad "replay left no structured trace"

##############################################################################
sec "3. Scheduled reconcile — the sweep repairs a loss NO error ever reported"
##############################################################################
# The mongo.reconcile knob, end to end: reboot with the sweep enabled on a
# 1-minute cadence, then delete a document DIRECTLY from the active Mongo slot
# — the loss class where nothing fails, nothing parks, and no ledger row
# exists (an operator mistake, a rolled-back write). Only the parity sweep
# can ever notice; it must bring the document back with no manual action.

title "3.1 Reboot with mongo.reconcile enabled (intervalMinutes: 1, unthrottled)"
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""
kill_port "$HTTP_PORT"
DERIVED_YAML="/tmp/omnicore-example-users-qa-projres-${BACKEND:-postgres}.yaml"
sed 's|^  database:\(.*\)$|  database:\1\n  reconcile:\n    enabled: true\n    intervalMinutes: 1\n    rowsPerSecond: -1|' \
  "$REPO_ROOT/microservice.dev.yaml" > "$DERIVED_YAML"
grep -q "reconcile:" "$DERIVED_YAML" || { bad "derived yaml missing reconcile block"; exit 1; }
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$DERIVED_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server rebooted with the sweep scheduled" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }
grep -q "projection reconcile loop started" "$SERVER_LOG" && ok "reconcile loop announced at boot" || bad "boot log missing the reconcile loop announcement"

title "3.2 Delete user B's document DIRECTLY from the active slot (no event, no error, no ledger row)"
UCOLL=$(qa_view_coll users)
docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval "db.getCollection('$UCOLL').deleteOne({_id:'$UB'})" >/dev/null
wait_status "/users/$UB" 404 15 && ok "document gone — the API now 404s a live SoR row (the silent-divergence state)" || bad "document still served after direct deletion"

title "3.3 The sweep notices and repairs with no manual action (≤ ~1 sweep interval + pass)"
# The two-pass confirm happens INSIDE a pass (suspect → grace → recheck →
# repair), so the fix lands in the first pass that scans the row after the
# deletion. Budget: one full interval + a pass + slack.
wait_status "/users/$UB" 200 180 && ok "document repaired by the parity sweep" || bad "sweep never repaired the deleted document"
if grep -q '"msg":"projection.reconcile.pass"' "$SERVER_LOG"; then
  ok "projection.reconcile.pass recorded (the clean/noisy denominator exists)"
else
  bad "no reconcile pass line in the server log"
fi

##############################################################################
sec "4. Teardown sanity"
##############################################################################
title "4.1 Delete the suite's users through the API (the honest path)"
for id in "$UA" "$UB"; do req DELETE "/users/$id"; done
ok "suite users deleted"

hr
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
