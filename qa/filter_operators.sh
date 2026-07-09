#!/usr/bin/env bash
# Filter-operator suite — the FULL query-filter vocabulary (all 16 operators),
# exercised on a live Mongo view through the qa-only Gadget mirror aggregate
# (`//go:build qa`). The canonical User/Employee DTOs declare only a subset, so
# several operators had zero coverage anywhere; Gadget's list DTO spreads every
# operator across its four fields:
#
#   Code     → eq, in, nin, gte, lte, gt, lt, startswith
#   Name     → eq, ne, startswith, contains, icontains, istartswith, ine
#   Category → eq, in, iin, inin, ieq
#   Status   → eq, ne, ieq, ine
#
# Plus the allowlist guard: an operator not declared on a leaf is rejected (400).
# Read-side, so it depends on CDC (gadgets outbox → gadgets.events → SyncEngine →
# Mongo) — the suite registers the Debezium connector and waits for the view.
#
# Self-managed; qa binary (-tags '<engine> qa') + microservice.qa.yaml.
# Dialect-driven via qa/_backend.sh.  Run from anywhere:  bash qa/filter_operators.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-filter-operators-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-filter-operators-${BACKEND:-postgres}.log"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port "${HTTP_PORT:-8080}"
  docker exec omnicore-qa-mongo mongosh "$QA_MONGO_DB" --quiet --eval 'db.gadgets.drop(); db.gadget_notes.drop(); db.gadgets_hot.drop(); db.gadgets_capped.drop(); db.upstream_gadgets.drop()' >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# gcount <name> <query-string> <expected-count> — GET the list, assert 200 AND
# the exact data length (deterministic fixtures make exact counts safe).
gcount() {
  local name="$1" qs="$2" want="$3"
  title "$name"
  local tmp; tmp=$(mktemp)
  local st; st=$(curl -sS -o "$tmp" -w "%{http_code}" -G "$BASE/qa/gadgets" --data-urlencode "$qs" -H "Accept-Language: en-US")
  local n; n=$(python3 -c 'import sys,json
try:
  d=json.load(open(sys.argv[1])); data=d.get("data",[])
  print(len(data) if isinstance(data,list) else -1)
except Exception: print(-1)' "$tmp")
  echo "GET /qa/gadgets?$qs → status=$st items=$n"
  if [ "$st" = "200" ] && [ "$n" = "$want" ]; then ok "$name (items=$n)"; else bad "$name (want status 200 items $want, got $st/$n)"; cat "$tmp" | head -c 300; echo; fi
  rm -f "$tmp"
}

# greject <name> <query-string> — assert the query is rejected 400 (operator not
# in the leaf's declared allowlist).
greject() {
  local name="$1" qs="$2"
  title "$name"
  local st; st=$(curl -sS -o /dev/null -w "%{http_code}" -G "$BASE/qa/gadgets" --data-urlencode "$qs")
  [ "$st" = "400" ] && ok "$name (400)" || bad "$name (want 400, got $st)"
}

##############################################################################
sec "0. Build qa binary + ensure connector + boot + seed"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"

title "0.2 Ensure the outbox Debezium connector is registered ($QA_CONNECTOR_DIALECT)"
# Idempotent — in the full run.sh matrix a long sequence of prior self-managed
# suites can leave the connector task degraded; re-register so the view materializes.
"$REPO_ROOT/devops/debezium/register-connector.sh" "$QA_CONNECTOR_DIALECT" >/dev/null 2>&1 \
  && ok "outbox connector registered" || bad "outbox connector registration failed"

title "0.3 Start server (APP_PROFILE=dev, config=microservice.qa.yaml)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$REPO_ROOT/microservice.qa.yaml" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/health" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready (PID=$SERVER_PID)" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }

# Prove the CDC pipeline is hot (consumer groups joined, Debezium task live)
# BEFORE any per-step deadline starts counting; the clean-baseline step below
# sweeps the sentinel. Non-fatal — see qa/_backend.sh.
qa_cdc_warmup_gadget

title "0.4 Reset + seed four ordered fixtures + wait for CDC"
qa_db_exec "DELETE FROM gadget_journal;" 2>/dev/null || true
qa_db_exec "DELETE FROM gadgets;"
docker exec omnicore-qa-mongo mongosh "$QA_MONGO_DB" --quiet --eval 'db.gadgets.deleteMany({})' >/dev/null 2>&1 || true
sleep 1
seed_g() {
  curl -sS -o /dev/null -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" \
    --data "{\"code\":\"$1\",\"name\":\"$2\",\"category\":\"$3\",\"status\":\"$4\"}"
}
seed_g "GADGET-01" "Alpha One"     "cat-a" "active"
seed_g "GADGET-02" "Bravo Two"     "cat-a" "inactive"
seed_g "GADGET-03" "Charlie Three" "cat-b" "active"
seed_g "GADGET-04" "Delta Four"    "cat-c" "retired"
# 60s tolerates the SyncEngine consumer-group rebalance after a long matrix of
# prior server boots.
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); seeded=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  c=$(curl -sS "$BASE/qa/gadgets?code.startswith=GADGET" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("data",[])))' 2>/dev/null)
  [ "${c:-0}" = "4" ] && { seeded=ok; break; }
  sleep 1
done
[ "$seeded" = ok ] && ok "four fixtures materialized in the gadgets view" || { bad "fixtures did not reach 4 (got ${c:-0})"; }

##############################################################################
sec "1. Code leaf — eq, in, nin, gte, lte, gt, lt, startswith"
##############################################################################
gcount "1.1 code.eq=GADGET-02"                 "code.eq=GADGET-02"           1
gcount "1.2 code.in=GADGET-01,GADGET-03"       "code.in=GADGET-01,GADGET-03" 2
gcount "1.3 code.nin=GADGET-01,GADGET-02"      "code.nin=GADGET-01,GADGET-02" 2
gcount "1.4 code.gte=GADGET-03 (>=)"           "code.gte=GADGET-03"          2
gcount "1.5 code.lte=GADGET-02 (<=)"           "code.lte=GADGET-02"          2
gcount "1.6 code.gt=GADGET-03 (>)"             "code.gt=GADGET-03"           1
gcount "1.7 code.lt=GADGET-02 (<)"             "code.lt=GADGET-02"           1
gcount "1.8 code.startswith=GADGET"            "code.startswith=GADGET"      4

##############################################################################
sec "2. Name leaf — eq, ne, startswith, contains, icontains, istartswith, ine"
##############################################################################
gcount "2.1 name.eq=Alpha One"                 "name.eq=Alpha One"           1
gcount "2.2 name.ne=Alpha One"                 "name.ne=Alpha One"           3
gcount "2.3 name.startswith=Bravo"             "name.startswith=Bravo"       1
gcount "2.4 name.contains=Three (cs substr)"   "name.contains=Three"         1
gcount "2.5 name.contains=three (cs miss)"     "name.contains=three"         0
gcount "2.6 name.icontains=three (ci substr)"  "name.icontains=three"        1
gcount "2.7 name.istartswith=alpha (ci pfx)"   "name.istartswith=alpha"      1
gcount "2.8 name.ine=ALPHA ONE (ci !=)"        "name.ine=ALPHA ONE"          3

##############################################################################
sec "3. Category leaf — eq, in, iin, inin, ieq"
##############################################################################
gcount "3.1 category.eq=cat-a"                 "category.eq=cat-a"           2
gcount "3.2 category.in=cat-b,cat-c"           "category.in=cat-b,cat-c"     2
gcount "3.3 category.iin=CAT-A (ci in-list)"   "category.iin=CAT-A"          2
gcount "3.4 category.inin=CAT-A (ci not-in)"   "category.inin=CAT-A"         2
gcount "3.5 category.ieq=CAT-B (ci ==)"        "category.ieq=CAT-B"          1

##############################################################################
sec "4. Status leaf — eq, ne, ieq, ine"
##############################################################################
gcount "4.1 status.eq=active"                  "status.eq=active"            2
gcount "4.2 status.ne=active"                  "status.ne=active"            2
gcount "4.3 status.ieq=ACTIVE (ci ==)"         "status.ieq=ACTIVE"           2
gcount "4.4 status.ine=ACTIVE (ci !=)"         "status.ine=ACTIVE"           2

##############################################################################
sec "5. Allowlist is exact — an undeclared operator on a leaf → 400"
##############################################################################
greject "5.1 status.gte rejected (Status declares no ordinals)" "status.gte=a"
greject "5.2 category.startswith rejected (Category declares no substring)" "category.startswith=cat"
greject "5.3 code.contains rejected (Code declares no substring ops)" "code.contains=GADGET"

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
