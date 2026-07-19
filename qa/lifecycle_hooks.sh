#!/usr/bin/env bash
# Lifecycle-hooks suite — the in-TX write hooks the canonical example never
# wires. Exercised through the qa-only Gadget mirror aggregate (`//go:build qa`,
# compiled only into this suite's binary), it proves the two hook slots on BOTH
# the Auto command path and the manual custom-handler path, plus a forced
# rollback:
#
#   AfterBegin  (slot A) — fires after BEGIN, before any framework write
#   BeforeCommit (slot D) — fires after data + outbox + audit, before COMMIT
#
# Each hook writes a gadget_journal row (via the neutral Tx / UnwrapTx), so the
# assertions read the relational journal directly — no CDC / Mongo involved.
# The forced rollback (Code=POISON) makes BeforeCommit error and proves the whole
# TX reverts (the gadget row AND both journal rows vanish together).
#
# Self-managed; qa binary (-tags '<engine> qa') + microservice.qa.yaml.
# Dialect-driven via qa/_backend.sh.  Run from anywhere:  bash qa/lifecycle_hooks.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-lifecycle-hooks-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-lifecycle-hooks-${BACKEND:-postgres}.log"

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
  # A qa-binary boot creates the gadget Mongo collections via view registration;
  # drop them so a later non-qa prd suite (audit/authz) does not abort on foreign
  # collections.
  qa_view_drop gadgets gadget_notes gadgets_hot gadgets_capped upstream_gadgets
}
trap cleanup EXIT INT TERM

##############################################################################
sec "0. Build qa binary + boot + reset gadget state"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"

title "0.2 Start server (APP_PROFILE=dev, config=microservice.qa.yaml)"
# microservice.qa.yaml is dev.yaml + the qa integration/upstream wiring the
# Gadget feature registers; the profile stays dev, only the config file swaps.
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$REPO_ROOT/microservice.qa.yaml" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready (PID=$SERVER_PID)" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }

title "0.3 Reset gadgets + gadget_journal (SQL)"
qa_db_exec "DELETE FROM gadget_journal;"
qa_db_exec "DELETE FROM gadgets;"
ok "clean gadget baseline"

##############################################################################
sec "1. AfterBegin + BeforeCommit on the Auto command path + journal"
##############################################################################
title "1.1 POST /qa/gadgets (Auto) → 201"
RESP=$(curl -sS -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" \
  --data '{"code":"HOOK-A","name":"Hook Auto","category":"hooks","status":"active"}')
GID_A=$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null)
[ -n "$GID_A" ] && ok "auto insert returned id $GID_A" || { bad "auto insert failed: $RESP"; }

title "1.2 Journal carries before-write (no id) + after-write (with id)"
BEFORE_PHASE=$(qa_db_query "SELECT count(*) FROM gadget_journal WHERE phase='before-write' AND gadget_id IS NULL;")
AFTER_PHASE=$(qa_db_query "SELECT count(*) FROM gadget_journal WHERE phase='after-write' AND gadget_id IS NOT NULL;")
[ "$BEFORE_PHASE" = "1" ] && ok "AfterBegin wrote 1 before-write row (no gadget_id yet)" || bad "before-write rows=$BEFORE_PHASE (want 1)"
[ "$AFTER_PHASE" = "1" ] && ok "BeforeCommit wrote 1 after-write row (with gadget_id)" || bad "after-write rows=$AFTER_PHASE (want 1)"

##############################################################################
sec "2. The manual custom-handler path (WithAfterBegin / WithBeforeCommit)"
##############################################################################
title "2.1 POST /qa/gadgets/custom → 201 (closure hooks, same journal shape)"
JB=$(qa_db_query "SELECT count(*) FROM gadget_journal;")
ST=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE/qa/gadgets/custom" -H "Content-Type: application/json" \
  --data '{"code":"HOOK-M","name":"Hook Manual","category":"hooks","status":"active"}')
JA=$(qa_db_query "SELECT count(*) FROM gadget_journal;")
[ "$ST" = "201" ] && ok "manual insert 201" || bad "manual insert status $ST"
[ "$JA" = "$((JB + 2))" ] && ok "manual path wrote 2 journal rows (hook invariance Auto == manual)" || bad "manual journal delta $JB→$JA (want +2)"

##############################################################################
sec "3. Hook error rolls the WHOLE TX back (data + journal + outbox)"
##############################################################################
title "3.1 POST code=POISON → BeforeCommit errors → 500 + nothing persists"
GB=$(qa_db_query "SELECT count(*) FROM gadgets;")
JB=$(qa_db_query "SELECT count(*) FROM gadget_journal;")
ST=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" \
  --data '{"code":"POISON","name":"Poison","category":"hooks","status":"active"}')
GA=$(qa_db_query "SELECT count(*) FROM gadgets;")
JA=$(qa_db_query "SELECT count(*) FROM gadget_journal;")
[ "$ST" = "500" ] && ok "poison insert rejected (500 from the hook error)" || bad "poison status $ST (want 500)"
[ "$GA" = "$GB" ] && ok "no gadget row persisted ($GB == $GA) — data rolled back" || bad "gadgets $GB→$GA (want unchanged)"
[ "$JA" = "$JB" ] && ok "no journal row persisted ($JB == $JA) — the AfterBegin write rolled back too" || bad "journal $JB→$JA (want unchanged)"

##############################################################################
sec "4. Cleanup"
##############################################################################
qa_db_exec "DELETE FROM gadget_journal;"
qa_db_exec "DELETE FROM gadgets;"
ok "gadget tables cleared"

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
