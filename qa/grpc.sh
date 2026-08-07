#!/usr/bin/env bash
# gRPC surface suite — the Wiring.GRPC listener (yaml `grpc:` block, :9090)
# serving the UsersService (proto/users/v1/users.proto) through the SAME
# application handlers as REST/GraphQL. Driven with curl via the Connect
# protocol's JSON mapping (one endpoint speaks gRPC, gRPC-Web and Connect;
# the gRPC-protocol interop itself is unit-locked in the framework suite).
#
# Covers:
#   - CreateUser happy path (200, id assigned)
#   - validation failure → invalid_argument + NotificationKey in
#     google.rpc.ErrorInfo details (the envelope crosses the wire)
#   - duplicate active user → already_exists (SemanticConflict mapping)
#   - inactive/legacy-state rejections ride FAILED_PRECONDITION
#     (SemanticStateConflict) — asserted indirectly via the semantic
#     metadata emitted with each ErrorInfo
#   - ListUsers: equality filter, only_total, X-Request-ID echo
#   - the only_total CONFLICT MATRIX (REST e2e §17 parity): only-total +
#     each page-shaping control (first/last/after/before/orderBy/fields) →
#     invalid_argument with the onlyTotal[<key>] marker; filters, search
#     and include_archived stay valid in count mode; only_total=false
#     behaves as omitted
#   - fields/orderBy vocabulary guards: an undeclared fields path or orderBy
#     field → invalid_argument (the Fields allowlist, REST tag parity)
#   - the WIRE-TYPE matrix (EchoTypes fixture): every proto scalar kind
#     through the pb↔DTO bridge in both directions — the 64-bit integers
#     protojson quotes (money as int64), at their extremes and past 2^53,
#     scalar/repeated/nested, presence, and the rejections that must stay
#
# Self-managed; qa binary + microservice.qa.yaml. Dialect-driven via
# _backend.sh. Run from anywhere:  bash qa/grpc.sh
set -u

BASE="${BASE:-http://localhost:8080}"
GRPC_BASE="${GRPC_BASE:-http://localhost:9090}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-grpc-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-grpc-${BACKEND:-postgres}.log"
POSTURE_YAML="/tmp/omnicore-qa-grpc-internal.yaml"
POSTURE_KEY="/tmp/omnicore-qa-grpc-posture.key"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port "${HTTP_PORT:-8080}"; kill_port "${GRPC_PORT:-9090}"
  rm -f "$POSTURE_YAML" "$POSTURE_KEY" "$POSTURE_KEY.pub"
}
trap cleanup EXIT INT TERM

# rpc <procedure> <json-body> [curl-extra...] — Connect JSON call; body → $RPC_BODY, status → $RPC_STATUS
rpc() {
  local procedure="$1" body="$2"; shift 2
  local tmp; tmp=$(mktemp)
  RPC_STATUS=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    "$GRPC_BASE/users.v1.UsersService/$procedure" -d "$body" "$@")
  RPC_BODY=$(cat "$tmp"); rm -f "$tmp"
}

##############################################################################
sec "0. Build qa binary + boot"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"; kill_port "${GRPC_PORT:-9090}"

title "0.2 Reset bench (relational domain tables + Mongo users view)"
qa_db_reset_domain
qa_mongo_reset
# A pre-wipe INSERT still in the CDC relay backlog (SQL Server capture job ~5s)
# would replay as a ghost document after the wipe — ground the broker tail too,
# matching schema_evolution / rebuild_scale.
qa_broker_reset
sleep 2

title "0.3 Start server (config=microservice.qa.yaml)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$REPO_ROOT/microservice.qa.yaml" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "http ready" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }
grep -q "grpc listening" "$SERVER_LOG" && ok "grpc listener up (:9090)" || { bad "grpc listener missing in log"; tail -n 30 "$SERVER_LOG"; exit 1; }

title "0.4 CDC warmup + clean gadget baseline"
# This suite READS Mongo projections (GetUser by id, the ListUsers/ListGadgets
# sections), so the pipeline must be hot BEFORE any per-step deadline starts
# counting — the same posture every other projection-reading self-managed suite
# takes. Non-fatal; the suite's own polls still apply.
qa_cdc_warmup_gadget
# 6e seeds three gadgets and asserts ABSOLUTE totals, so it needs an empty
# baseline: qa_mongo_reset covers the canonical views only, and nothing else
# clears the qa gadget family — without this, every re-run on a lane multiplies
# the counts (and sweeps the warmup sentinel above).
qa_db_exec "DELETE FROM gadget_notes;" 2>/dev/null || true
qa_db_exec "DELETE FROM gadgets;" 2>/dev/null || true
qa_view_clear gadgets
sleep 1

title "0.5 Ground the relay backlog on the USERS topic (sentinel drain)"
# qa_broker_reset (0.2) moves the sync group to LATEST — it never deletes a
# message and never touches the producer, so it can only ground what was
# ALREADY produced. A lagging capture stage ships pre-wipe events into the
# broker AFTER that reset (SQL Server's CDC capture job polls ~5s behind;
# Oracle LogMiner ~2-3s), and those late events materialize ghost documents —
# which is how 6c.4's `IN` counted 6 rows for 2 users on the sqlserver lane.
# Same remedy the schema_evolution / rebuild_scale suites already carry, and it
# must ride the USERS topic: the gadget warmup above proves nothing about this
# one (ordering is per topic). When the sentinel's own document appears, every
# earlier users event was consumed; when its delete propagates, the tail is
# quiet — then the ghosts the backlog let through are swept.
users_coll=$(qa_view_coll users)
sentinel_doc="10000000998"
curl -sS -o /tmp/qa-grpc-sentinel-${BACKEND}.json -X POST "$BASE/users" -H "Content-Type: application/json" \
  --data "{\"name\":\"Drain Sentinel\",\"email\":\"drain.grpc@example.test\",\"phone\":\"14155552671\",\"document\":\"$sentinel_doc\",\"userName\":\"$sentinel_doc\",\"ethnicity\":\"white\",\"userProfile\":1,\"addresses\":[]}" >/dev/null 2>&1
sentinel_id=$(grep -o '"id":"[^"]*"' "/tmp/qa-grpc-sentinel-${BACKEND}.json" 2>/dev/null | head -1 | cut -d'"' -f4)
sentinel_count() {
  docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet \
    --eval "print(db.getCollection('$users_coll').countDocuments({_id:'$sentinel_id'}))" 2>/dev/null | tail -1 | tr -d ' '
}
if [ -n "$sentinel_id" ]; then
  deadline=$(( $(date +%s) + QA_CDC_DEADLINE ))
  while [ "$(date +%s)" -lt "$deadline" ]; do [ "$(sentinel_count)" = "1" ] && break; sleep 1; done
  curl -sS -o /dev/null -X DELETE "$BASE/users/$sentinel_id" 2>/dev/null
  deadline=$(( $(date +%s) + QA_CDC_DEADLINE ))
  while [ "$(date +%s)" -lt "$deadline" ]; do [ "$(sentinel_count)" = "0" ] && break; sleep 1; done
  ok "users relay backlog drained (sentinel $sentinel_id)"
else
  bad "sentinel user was not created — the backlog could not be drained"
fi
# Sweep whatever the late backlog materialized before the drain completed.
qa_view_clear users
rm -f "/tmp/qa-grpc-sentinel-${BACKEND}.json"

##############################################################################
sec "1. CreateUser — happy path"
##############################################################################
title "1.1 CreateUser → 200 with assigned id"
rpc CreateUser '{"name":"Grpc Alice","email":"grpc.alice@example.com","document":"99091000001","userName":"grpcqa_alice","phone":"14155550001","ethnicity":"white","userProfile":1}'
echo "status=$RPC_STATUS body=${RPC_BODY:0:160}"
if [ "$RPC_STATUS" = "200" ] && echo "$RPC_BODY" | grep -q '"id":"' && echo "$RPC_BODY" | grep -q '"userName":"grpcqa_alice"'; then
  ok "CreateUser 200 + id + userName"
else
  bad "CreateUser (want 200+id, got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi
USER_ID=$(echo "$RPC_BODY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

##############################################################################
sec "2. Validation → invalid_argument with the notification envelope"
##############################################################################
title "2.1 CreateUser with empty name → invalid_argument + RequiredFieldNotification"
rpc CreateUser '{"name":"","email":"grpc.bad@example.com","document":"99091000002","userName":"grpcqa_bad","ethnicity":"white","userProfile":1}'
echo "status=$RPC_STATUS body=${RPC_BODY:0:200}"
if [ "$RPC_STATUS" = "400" ] && echo "$RPC_BODY" | grep -q '"code":"invalid_argument"' \
   && echo "$RPC_BODY" | grep -q 'RequiredFieldNotification'; then
  ok "invalid_argument + NotificationKey in details"
else
  bad "validation mapping (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 400; echo
fi

title "2.2 details carry the semantic metadata (Validation)"
if echo "$RPC_BODY" | grep -q '"semantic":"Validation"'; then
  ok "ErrorInfo.metadata.semantic = Validation"
else
  bad "semantic metadata missing"; echo "$RPC_BODY" | head -c 400; echo
fi

##############################################################################
sec "3. Duplicate active user → already_exists (SemanticConflict)"
##############################################################################
title "3.1 Re-CreateUser same document → already_exists"
rpc CreateUser '{"name":"Grpc Alice","email":"grpc.alice@example.com","document":"99091000001","userName":"grpcqa_alice","ethnicity":"white","userProfile":1}'
echo "status=$RPC_STATUS body=${RPC_BODY:0:200}"
if [ "$RPC_STATUS" = "409" ] && echo "$RPC_BODY" | grep -q '"code":"already_exists"' \
   && echo "$RPC_BODY" | grep -q 'EntityAlreadyAddedNotification'; then
  ok "already_exists + EntityAlreadyAddedNotification"
else
  bad "conflict mapping (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 400; echo
fi

##############################################################################
sec "4. ListUsers — filter, only_total, correlation echo"
##############################################################################
title "4.1 ListUsers user_name=grpcqa_alice → total 1 (poll: projection is async)"
deadline=$(( $(date +%s) + 15 )); found=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  rpc ListUsers '{"filters":{"userName":{"conditions":[{"op":"STRING_OP_EQ","values":["grpcqa_alice"]}]}}}'
  echo "$RPC_BODY" | grep -q '"totalCount":"1"\|"totalCount":1' && { found=ok; break; }
  sleep 0.5
done
echo "status=$RPC_STATUS body=${RPC_BODY:0:200}"
if [ "$found" = ok ] && echo "$RPC_BODY" | grep -q '"userName":"grpcqa_alice"'; then
  ok "equality filter + projected item"
else
  bad "ListUsers filter"; echo "$RPC_BODY" | head -c 400; echo
fi

title "4.2 only_total → total without items"
rpc ListUsers '{"pagination":{"onlyTotal":true}}'
if [ "$RPC_STATUS" = "200" ] && ! echo "$RPC_BODY" | grep -q '"items"'; then
  ok "only_total suppresses items"
else
  bad "only_total (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

title "4.3 icontains filter + orderBy + fields (shared omnicore.v1 components)"
rpc ListUsers '{"filters":{"userName":{"conditions":[{"op":"STRING_OP_ICONTAINS","values":["GRPCQA"]}]}},"orderBy":[{"field":"user_name","desc":true}],"fields":"id,userName"}'
echo "status=$RPC_STATUS body=${RPC_BODY:0:200}"
if [ "$RPC_STATUS" = "200" ] && echo "$RPC_BODY" | grep -q '"userName":"grpcqa_alice"' \
   && ! echo "$RPC_BODY" | grep -q '"email"'; then
  ok "contains + orderBy + fields projection (email masked out)"
else
  bad "typed criteria"; echo "$RPC_BODY" | head -c 400; echo
fi

title "4.4 invalid operator → invalid_argument (SchemaViolation)"
rpc ListUsers '{"filters":{"userName":{"conditions":[{"op":"STRING_OP_UNSPECIFIED","values":["x"]}]}}}'
if [ "$RPC_STATUS" = "400" ] && echo "$RPC_BODY" | grep -q 'SchemaViolationNotification'; then
  ok "unspecified op rejected as schema violation"
else
  bad "invalid op (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

title "4.5 X-Request-ID echoes on the RPC response"
RID="11111111-2222-3333-4444-555555555555"
hdrs=$(curl -sS -o /dev/null -D - -X POST -H "Content-Type: application/json" \
  -H "X-Request-ID: $RID" "$GRPC_BASE/users.v1.UsersService/ListUsers" -d '{}')
if echo "$hdrs" | grep -qi "x-request-id: $RID"; then
  ok "X-Request-ID echoed"
else
  bad "X-Request-ID not echoed"; echo "$hdrs" | head -5
fi

##############################################################################
sec "5. GetUser — QueryByID"
##############################################################################
title "5.1 GetUser by created id → 200 (poll: projection is async)"
deadline=$(( $(date +%s) + 15 )); found=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  rpc GetUser "{\"id\":\"$USER_ID\"}"
  [ "$RPC_STATUS" = "200" ] && echo "$RPC_BODY" | grep -q '"userName":"grpcqa_alice"' && { found=ok; break; }
  sleep 0.5
done
echo "status=$RPC_STATUS body=${RPC_BODY:0:160}"
if [ "$found" = ok ]; then
  ok "GetUser 200 + projected doc"
else
  bad "GetUser by id"; echo "$RPC_BODY" | head -c 300; echo
fi

title "5.2 GetUser unknown id → not_found"
rpc GetUser '{"id":"00000000-0000-0000-0000-000000000000"}'
if [ "$RPC_STATUS" = "404" ] && echo "$RPC_BODY" | grep -q '"code":"not_found"'; then
  ok "not_found + 404"
else
  bad "GetUser unknown (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

##############################################################################
sec "6. ArchiveUser — CommandByID + hidden-by-default invariant"
##############################################################################
title "6.1 ArchiveUser → 200"
rpc ArchiveUser "{\"id\":\"$USER_ID\"}"
if [ "$RPC_STATUS" = "200" ]; then
  ok "ArchiveUser 200"
else
  bad "ArchiveUser (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

title "6.2 GetUser default now hides the archived user (poll)"
deadline=$(( $(date +%s) + 15 )); hidden=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  rpc GetUser "{\"id\":\"$USER_ID\"}"
  [ "$RPC_STATUS" = "404" ] && { hidden=ok; break; }
  sleep 0.5
done
if [ "$hidden" = ok ]; then
  ok "archived hidden by default (not_found)"
else
  bad "archived still visible (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 200; echo
fi

title "6.3 GetUser include_archived=true surfaces it"
rpc GetUser "{\"id\":\"$USER_ID\",\"includeArchived\":true}"
if [ "$RPC_STATUS" = "200" ] && echo "$RPC_BODY" | grep -q '"userName":"grpcqa_alice"'; then
  ok "include_archived surfaces the archived user"
else
  bad "include_archived (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

##############################################################################
sec "6b. UpdateUser — CommandWithBodyID (the PUT sibling)"
##############################################################################
title "6b.1 seed a fresh user"
rpc CreateUser '{"name":"Grpc Carol","email":"grpc.carol@example.com","document":"99091000003","userName":"grpcqa_carol","ethnicity":"white","userProfile":1}'
CAROL_ID=$(echo "$RPC_BODY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -n "$CAROL_ID" ] && ok "carol created" || { bad "carol create"; echo "$RPC_BODY" | head -c 300; }

title "6b.2 UpdateUser full body → 200 with the new values"
rpc UpdateUser "{\"id\":\"$CAROL_ID\",\"name\":\"Carol Renamed\",\"email\":\"carol.renamed@example.com\",\"userName\":\"grpcqa_carol\",\"ethnicity\":\"white\",\"userProfile\":1,\"addresses\":[]}"
echo "status=$RPC_STATUS body=${RPC_BODY:0:160}"
if [ "$RPC_STATUS" = "200" ] && echo "$RPC_BODY" | grep -q '"name":"Carol Renamed"'; then
  ok "update applied"
else
  bad "update (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 400; echo
fi

title "6b.3 strict body: missing email/user_name → invalid_argument + RequiredField"
rpc UpdateUser "{\"id\":\"$CAROL_ID\",\"name\":\"OnlyName\"}"
if [ "$RPC_STATUS" = "400" ] && echo "$RPC_BODY" | grep -q 'RequiredFieldNotification' \
   && echo "$RPC_BODY" | grep -q '"field":"email"' && echo "$RPC_BODY" | grep -q '"field":"user_name"'; then
  ok "Strict flags every missing field"
else
  bad "strict (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 400; echo
fi

title "6b.4 UpdateUser unknown id → not_found"
rpc UpdateUser '{"id":"00000000-0000-0000-0000-000000000000","name":"X","email":"x@example.com","userName":"ghost","ethnicity":"white","userProfile":1,"addresses":[]}'
if [ "$RPC_STATUS" = "404" ] && echo "$RPC_BODY" | grep -q '"code":"not_found"'; then
  ok "unknown id → not_found"
else
  bad "unknown id (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

##############################################################################
sec "6c. Pagination + filter vocabulary over the shared components"
##############################################################################
title "6c.1 seed dave (poll list until both project)"
rpc CreateUser '{"name":"Grpc Dave","email":"grpc.dave@example.com","document":"99091000004","userName":"grpcqa_dave","ethnicity":"white","userProfile":1}'
deadline=$(( $(date +%s) + 15 )); seeded=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  rpc ListUsers '{"filters":{"userName":{"conditions":[{"op":"STRING_OP_STARTSWITH","values":["grpcqa_"]}]}},"pagination":{"onlyTotal":true}}'
  echo "$RPC_BODY" | grep -Eq '"totalCount":"?2"?' && { seeded=ok; break; }
  sleep 0.5
done
[ "$seeded" = ok ] && ok "carol + dave projected (alice hidden as archived)" || { bad "seeding"; echo "$RPC_BODY" | head -c 200; }

title "6c.2 page 1: orderBy userName asc, first 1 → carol + endCursor"
rpc ListUsers '{"filters":{"userName":{"conditions":[{"op":"STRING_OP_STARTSWITH","values":["grpcqa_"]}]}},"orderBy":[{"field":"user_name"}],"pagination":{"first":1}}'
CURSOR=$(echo "$RPC_BODY" | grep -o '"endCursor":"[^"]*"' | cut -d'"' -f4)
if echo "$RPC_BODY" | grep -q '"userName":"grpcqa_carol"' && [ -n "$CURSOR" ]; then
  ok "page 1 = carol, cursor issued"
else
  bad "page 1"; echo "$RPC_BODY" | head -c 300; echo
fi

title "6c.3 page 2: after=cursor → dave"
rpc ListUsers "{\"filters\":{\"userName\":{\"conditions\":[{\"op\":\"STRING_OP_STARTSWITH\",\"values\":[\"grpcqa_\"]}]}},\"orderBy\":[{\"field\":\"user_name\"}],\"pagination\":{\"first\":1,\"after\":\"$CURSOR\"}}"
if echo "$RPC_BODY" | grep -q '"userName":"grpcqa_dave"' && ! echo "$RPC_BODY" | grep -q 'grpcqa_carol'; then
  ok "cursor walk reaches dave only"
else
  bad "page 2"; echo "$RPC_BODY" | head -c 300; echo
fi

title "6c.4 IN filter with multiple values"
rpc ListUsers '{"filters":{"email":{"conditions":[{"op":"STRING_OP_IN","values":["carol.renamed@example.com","grpc.dave@example.com"]}]}},"pagination":{"onlyTotal":true}}'
if echo "$RPC_BODY" | grep -Eq '"totalCount":"?2"?'; then ok "IN matches both"; else bad "IN"; echo "$RPC_BODY" | head -c 200; fi

title "6c.5 include_archived resurfaces alice in the count"
rpc ListUsers '{"filters":{"userName":{"conditions":[{"op":"STRING_OP_STARTSWITH","values":["grpcqa_"]}]}},"pagination":{"onlyTotal":true,"includeArchived":true}}'
if echo "$RPC_BODY" | grep -Eq '"totalCount":"?3"?'; then ok "archived included on opt-in"; else bad "includeArchived"; echo "$RPC_BODY" | head -c 200; fi

##############################################################################
sec "6d. The FULL Semantic → code table (Provoke fixture)"
##############################################################################
title "6d.1 every semantic maps to its canonical connect code"
SEMANTIC_OK=0
while read -r sem code; do
  RPC_ST=$(curl -sS -o /tmp/grpc-provoke.json -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    "$GRPC_BASE/qafixtures.v1.QAService/Provoke" -d "{\"semantic\":\"$sem\"}")
  if grep -q "\"code\":\"$code\"" /tmp/grpc-provoke.json; then
    SEMANTIC_OK=$((SEMANTIC_OK+1))
  else
    bad "semantic $sem → wanted $code (HTTP $RPC_ST)"; head -c 200 /tmp/grpc-provoke.json; echo
  fi
done <<'TABLE'
validation invalid_argument
schema invalid_argument
not_found not_found
conflict already_exists
state_conflict failed_precondition
forbidden permission_denied
unauthorized unauthenticated
unavailable unavailable
method_not_allowed unimplemented
payload_too_large resource_exhausted
gateway_timeout deadline_exceeded
TABLE
[ "$SEMANTIC_OK" = "11" ] && ok "11/11 semantics mapped" || bad "semantic table ($SEMANTIC_OK/11)"

title "6d.2 internal (exception path) is opaque"
curl -sS -o /tmp/grpc-provoke.json -X POST -H "Content-Type: application/json" \
  "$GRPC_BASE/qafixtures.v1.QAService/Provoke" -d '{"semantic":"internal"}' >/dev/null
if grep -q '"code":"internal"' /tmp/grpc-provoke.json && ! grep -q "never reach the wire" /tmp/grpc-provoke.json; then
  ok "exception opaque (no leak)"
else
  bad "internal leak"; head -c 300 /tmp/grpc-provoke.json; echo
fi

##############################################################################
sec "6e. The COMPLETE StringOp vocabulary (gadgets fixture view)"
##############################################################################
title "6e.1 seed gadgets via REST + poll projection"
curl -sS -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" -d '{"code":"ALPHA-1","name":"Rocket Saw","category":"tools","status":"active"}' >/dev/null
curl -sS -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" -d '{"code":"BETA-2","name":"Rocket Drill","category":"tools","status":"inactive"}' >/dev/null
curl -sS -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" -d '{"code":"GAMMA-3","name":"Hammer","category":"garden","status":"active"}' >/dev/null
gtotal() { # gtotal <field> <op> <values-json>
  curl -sS -X POST -H "Content-Type: application/json" \
    "$GRPC_BASE/qafixtures.v1.QAService/ListGadgets" \
    -d "{\"filters\":{\"$1\":{\"conditions\":[{\"op\":\"$2\",\"values\":$3}]}},\"pagination\":{\"onlyTotal\":true}}" \
    | grep -o '"totalCount":"\{0,1\}[0-9]*' | grep -o '[0-9]*$'
}
deadline=$(( $(date +%s) + 15 )); seeded=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ "$(gtotal name STRING_OP_CONTAINS '[""]' 2>/dev/null || echo 0)" = "3" ] && { seeded=ok; break; }
  sleep 0.5
done
[ "$seeded" = ok ] && ok "3 gadgets projected" || bad "gadget seeding"

title "6e.2 the 12 operators, one by one"
OPS_OK=0
check_op() { # check_op <label> <field> <op> <values> <want>
  local got; got=$(gtotal "$2" "$3" "$4")
  if [ "$got" = "$5" ]; then OPS_OK=$((OPS_OK+1)); else bad "$1 (want $5, got ${got:-none})"; fi
}
check_op eq          name     STRING_OP_EQ          '["Hammer"]'            1
check_op ne          name     STRING_OP_NE          '["Hammer"]'            2
check_op in          code     STRING_OP_IN          '["ALPHA-1","GAMMA-3"]' 2
check_op nin         code     STRING_OP_NIN         '["ALPHA-1"]'           2
check_op startswith  name     STRING_OP_STARTSWITH  '["Rocket"]'            2
check_op contains    name     STRING_OP_CONTAINS    '["ck"]'                2
check_op ieq         status   STRING_OP_IEQ         '["ACTIVE"]'            2
check_op ine         name     STRING_OP_INE         '["hammer"]'            2
check_op istartswith name     STRING_OP_ISTARTSWITH '["rock"]'              2
check_op icontains   name     STRING_OP_ICONTAINS   '["CK"]'                2
check_op iin         category STRING_OP_IIN         '["TOOLS"]'             2
check_op inin        category STRING_OP_ININ        '["TOOLS"]'             1
[ "$OPS_OK" = "12" ] && ok "12/12 StringOps behave like the REST vocabulary" || bad "operator vocabulary ($OPS_OK/12)"

title "6e.3 operator outside the leaf's filter: tag → invalid_argument (allowlist parity with REST)"
REJ=$(curl -sS -o /tmp/grpc-optag.json -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  "$GRPC_BASE/qafixtures.v1.QAService/ListGadgets" \
  -d '{"filters":{"category":{"conditions":[{"op":"STRING_OP_NE","values":["tools"]}]}},"pagination":{"onlyTotal":true}}')
if [ "$REJ" = "400" ] && grep -q '"code":"invalid_argument"' /tmp/grpc-optag.json && grep -q 'SchemaViolationNotification' /tmp/grpc-optag.json; then
  ok "ne on category (declared: eq,in,iin,inin,ieq) rejects with the allowlist"
else
  bad "filter-tag allowlist (status $REJ)"; head -c 300 /tmp/grpc-optag.json; echo
fi

title "6e.4 two ops on the same field AND-combine (MultiClause)"
RES=$(curl -sS -X POST -H "Content-Type: application/json" \
  "$GRPC_BASE/qafixtures.v1.QAService/ListGadgets" \
  -d '{"filters":{"name":{"conditions":[{"op":"STRING_OP_STARTSWITH","values":["Rocket"]},{"op":"STRING_OP_ICONTAINS","values":["DRILL"]}]}},"pagination":{"onlyTotal":true}}')
echo "$RES" | grep -Eq '"totalCount":"?1"?' && ok "AND-combined conditions" || { bad "MultiClause"; echo "$RES" | head -c 200; }

##############################################################################
sec "6f. Backward pagination (before + startCursor)"
##############################################################################
title "6f.1 walk forward to dave, then back to carol via startCursor"
rpc ListUsers '{"filters":{"userName":{"conditions":[{"op":"STRING_OP_STARTSWITH","values":["grpcqa_"]}]}},"orderBy":[{"field":"user_name"}],"pagination":{"first":1}}'
CUR_F=$(echo "$RPC_BODY" | grep -o '"endCursor":"[^"]*"' | cut -d'"' -f4)
rpc ListUsers "{\"filters\":{\"userName\":{\"conditions\":[{\"op\":\"STRING_OP_STARTSWITH\",\"values\":[\"grpcqa_\"]}]}},\"orderBy\":[{\"field\":\"user_name\"}],\"pagination\":{\"first\":1,\"after\":\"$CUR_F\"}}"
CUR_B=$(echo "$RPC_BODY" | grep -o '"startCursor":"[^"]*"' | cut -d'"' -f4)
if [ -n "$CUR_B" ] && echo "$RPC_BODY" | grep -q 'grpcqa_dave'; then
  rpc ListUsers "{\"filters\":{\"userName\":{\"conditions\":[{\"op\":\"STRING_OP_STARTSWITH\",\"values\":[\"grpcqa_\"]}]}},\"orderBy\":[{\"field\":\"user_name\"}],\"pagination\":{\"last\":1,\"before\":\"$CUR_B\"}}"
  if echo "$RPC_BODY" | grep -q 'grpcqa_carol' && ! echo "$RPC_BODY" | grep -q 'grpcqa_dave'; then
    ok "before-cursor walks back to carol"
  else
    bad "backward walk"; echo "$RPC_BODY" | head -c 300; echo
  fi
else
  bad "startCursor missing on page 2"; echo "$RPC_BODY" | head -c 300; echo
fi

# `last` WITHOUT a cursor is a direction on its own — it yields the LAST N of the
# ordered set (proto comment on PaginationRequest; REST parity e2e §15.9b). It is
# the one Relay leg the gRPC suite never exercised: 6f.1 only ever sent `last`
# paired with `before`, which the reader also infers backward from.
GRPC_PAGE='{"filters":{"userName":{"conditions":[{"op":"STRING_OP_STARTSWITH","values":["grpcqa_"]}]}},"orderBy":[{"field":"user_name"}],"pagination"'

title "6f.2 last:1 with NO cursor → the tail of the ordered set (dave)"
rpc ListUsers "${GRPC_PAGE}:{\"last\":1}}"
if [ "$RPC_STATUS" = "200" ] && echo "$RPC_BODY" | grep -q 'grpcqa_dave' \
   && ! echo "$RPC_BODY" | grep -q 'grpcqa_carol'; then
  ok "last:1 alone returns the tail window"
else
  bad "last:1 tail (status $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

# PaginationInfo is "the REST pagination block mirrored field-for-field"
# (query.proto), but no case ever read its boundary flags — the suite only ever
# harvested cursors. Connect serializes with protojson defaults, so a FALSE bool
# and an EMPTY string are OMITTED from the JSON: presence IS the assertion, and
# absence is the negative one. The reader also emits end_cursor only when
# has_next_page and start_cursor only when has_previous_page, so the two halves
# of each page must agree.
title "6f.3 page 1 envelope: has_next_page + end_cursor, no backward half"
rpc ListUsers "${GRPC_PAGE}:{\"first\":1}}"
if [ "$RPC_STATUS" = "200" ] && echo "$RPC_BODY" | grep -q '"hasNextPage":true' \
   && ! echo "$RPC_BODY" | grep -q 'hasPreviousPage' \
   && echo "$RPC_BODY" | grep -q '"endCursor"' \
   && ! echo "$RPC_BODY" | grep -q '"startCursor"'; then
  ok "head page: forward half populated, backward half absent"
else
  bad "page 1 envelope (status $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi
CUR_P1=$(echo "$RPC_BODY" | grep -o '"endCursor":"[^"]*"' | cut -d'"' -f4)

title "6f.4 page 2 (the tail) envelope: has_previous_page + start_cursor, no forward half"
rpc ListUsers "${GRPC_PAGE}:{\"first\":1,\"after\":\"$CUR_P1\"}}"
if [ "$RPC_STATUS" = "200" ] && echo "$RPC_BODY" | grep -q '"hasPreviousPage":true' \
   && ! echo "$RPC_BODY" | grep -q 'hasNextPage' \
   && echo "$RPC_BODY" | grep -q '"startCursor"' \
   && ! echo "$RPC_BODY" | grep -q '"endCursor"'; then
  ok "tail page: backward half populated, forward half absent"
else
  bad "page 2 envelope (status $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

##############################################################################
sec "6g. The WIRE-TYPE matrix (EchoTypes fixture)"
##############################################################################
# protojson and encoding/json speak the same JSON for most kinds and disagree
# on exactly one: the proto3 JSON mapping renders 64-bit integers (int64,
# sint64, sfixed64, uint64, fixed64) as QUOTED strings. A DTO that declares
# money as `int64` — the SAME seat REST and GraphQL bind — used to fail EVERY
# gRPC request with a SchemaViolation, before the command handler was ever
# reached. These cases walk every proto scalar kind through the bridge in
# BOTH directions, over a real connection.
#
# Wire form: 64-bit fields come BACK quoted (that IS the proto3 JSON mapping,
# and what a generated client expects) — the assertions match the wire
# exactly. sumCents is computed by the HANDLER, so a green sum proves the
# values arrived as numbers the domain can do arithmetic on, not as text.

qarpc() { # qarpc <procedure> <json> ; body → $Q_BODY, status → $Q_STATUS
  local tmp; tmp=$(mktemp)
  Q_STATUS=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    "$GRPC_BASE/qafixtures.v1.QAService/$1" -d "$2")
  Q_BODY=$(cat "$tmp"); rm -f "$tmp"
}
echoes() { # echoes <label> <request-json> <grep-pattern...>
  local label="$1" body="$2"; shift 2
  qarpc EchoTypes "$body"
  if [ "$Q_STATUS" != "200" ]; then
    bad "$label (HTTP $Q_STATUS)"; echo "$Q_BODY" | head -c 300; echo; return
  fi
  # protojson DELIBERATELY varies its whitespace between runs (an extra space
  # after a separator, to discourage byte-comparing its output), so a pattern
  # spanning a comma is unstable by construction. Match against the
  # space-stripped body — no assertion below carries a meaningful space.
  local norm; norm=$(printf '%s' "$Q_BODY" | tr -d ' ')
  local missing="" pat
  for pat in "$@"; do
    printf '%s' "$norm" | grep -q -- "$pat" || missing="$missing [$pat]"
  done
  if [ -z "$missing" ]; then ok "$label"; else bad "$label — missing:$missing"; echo "$Q_BODY" | head -c 400; echo; fi
}

title "6g.1 money as int64 — the shape that used to break"
echoes "quoted int64 (what a generated client sends) binds and sums" \
  '{"priceCents":"1050"}' '"priceCents":"1050"' '"sumCents":"1050"'
echoes "bare-number int64 is accepted too (protojson takes both forms)" \
  '{"priceCents":1050}' '"priceCents":"1050"' '"sumCents":"1050"'
echoes "negative money round-trips" \
  '{"priceCents":"-2500"}' '"priceCents":"-2500"' '"sumCents":"-2500"'

title "6g.2 all five 64-bit kinds, at their extremes, exact"
echoes "int64 max / sint64 min / sfixed64 / uint64 max / fixed64" \
  '{"priceCents":"9223372036854775807","signedDelta":"-9223372036854775808","fixedSigned":"-9007199254740993","hugeCount":"18446744073709551615","fixedUnsigned":"9007199254740993"}' \
  '"priceCents":"9223372036854775807"' '"signedDelta":"-9223372036854775808"' \
  '"fixedSigned":"-9007199254740993"' '"hugeCount":"18446744073709551615"' \
  '"fixedUnsigned":"9007199254740993"'

title "6g.3 the kinds the two dialects already agreed on"
echoes "int32 (negative), uint32, double, float, bool, string" \
  '{"quantity":-3,"unsignedQuantity":9,"weight":2.5,"ratio":0.5,"active":true,"label":"widget"}' \
  '"quantity":-3' '"unsignedQuantity":9' '"weight":2.5' '"ratio":0.5' '"active":true' '"label":"widget"'
echoes "bytes (base64 carrying + and /), enum member NAME, timestamp" \
  '{"payload":"+/+/Pn0=","flavor":"FLAVOR_SALTY","occurredAt":"2026-08-06T12:30:00Z"}' \
  '"payload":"+/+/Pn0="' '"flavor":"FLAVOR_SALTY"' '"occurredAt":"2026-08-06T12:30:00Z"'

title "6g.4 repeated fields, including the quoted-element kind"
echoes "repeated int64 (quoted elements) + repeated string, order kept" \
  '{"amounts":["1","9223372036854775806","-7"],"tags":["a","b"]}' \
  '"amounts":\["1","9223372036854775806","-7"\]' '"tags":\["a","b"\]' \
  '"sumCents":"9223372036854775800"'

title "6g.5 64-bit at depth — nested message and repeated nested"
echoes "child + children carry their own int64 through the child plan" \
  '{"child":{"childCents":"9007199254740993","childLabel":"kid"},"children":[{"childCents":"1","childLabel":"one"},{"childCents":"2","childLabel":"two"}]}' \
  '"childCents":"9007199254740993"' '"childLabel":"kid"' \
  '"childCents":"1"' '"childCents":"2"' '"sumCents":"9007199254740996"'

title "6g.6 the float64 trap: arithmetic past 2^53 stays exact"
# 9007199254740992 is 2^53; +1 is NOT representable as a float64 (it rounds
# back to 2^53). A green case proves nothing on either leg was routed
# through a float.
echoes "2^53 + 1 == 9007199254740993, not 9007199254740992" \
  '{"priceCents":"9007199254740992","amounts":["1"]}' '"sumCents":"9007199254740993"'
echoes "uint64 above int64's ceiling survives unsigned" \
  '{"hugeCount":"18446744073709551614"}' '"hugeCount":"18446744073709551614"'

title "6g.7 presence: absent optional vs explicitly empty"
qarpc EchoTypes '{"priceCents":"5"}'
if [ "$Q_STATUS" = "200" ] && ! echo "$Q_BODY" | grep -q '"labelPresent":true'; then
  ok "absent optional string stays absent (nil pointer at the DTO)"
else
  bad "absent-optional presence"; echo "$Q_BODY" | head -c 300; echo
fi
qarpc EchoTypes '{"label":""}'
if [ "$Q_STATUS" = "200" ] && echo "$Q_BODY" | grep -q '"labelPresent":true'; then
  ok "explicit empty string arrives SET (presence survives the rewrite)"
else
  bad "explicit-empty presence"; echo "$Q_BODY" | head -c 300; echo
fi

title "6g.8 the bridge stayed strict — a bad 64-bit value still rejects"
# Not text, not fractional, not out of range, no stray whitespace. The
# request is parsed into the proto FIRST, so these die at the wire contract,
# exactly as they did before the bridge learned to unquote.
for bogus in '"abc"' '"10.5"' '" 12"' '"9223372036854775808"' '"-9223372036854775809"'; do
  qarpc EchoTypes "{\"priceCents\":$bogus}"
  if [ "$Q_STATUS" = "400" ]; then
    ok "priceCents=$bogus rejected (invalid_argument)"
  else
    bad "priceCents=$bogus should reject, got HTTP $Q_STATUS"; echo "$Q_BODY" | head -c 200; echo
  fi
done
# The exponent form IS legal proto3 JSON for a numeric field when the value
# is an exact integer — it must be accepted and normalized, not rejected.
echoes "exponent notation for an int64 normalizes to 1000" \
  '{"priceCents":"1e3"}' '"priceCents":"1000"' '"sumCents":"1000"'

title "6g.8b non-finite floats reject — they must never bind as a silent zero"
# protojson renders (and accepts) NaN/Infinity/-Infinity as STRINGS for
# float/double. JSON has no literal for them, so the DTO's float64 seat cannot
# receive one — the framework rejects naming the field (the message itself is
# server-side; the wire contract asserted here is that it is a clean 400, never
# a 200 with a zeroed field and never a 500).
for special in NaN Infinity -Infinity; do
  for field in weight ratio; do
    qarpc EchoTypes "{\"$field\":\"$special\"}"
    if [ "$Q_STATUS" = "400" ]; then
      ok "$field=$special rejected (invalid_argument)"
    else
      bad "$field=$special should reject, got HTTP $Q_STATUS"; echo "$Q_BODY" | head -c 200; echo
    fi
  done
done
# …and the ordinary finite value on the SAME fields still round-trips, so the
# guard cannot be satisfied by rejecting floats wholesale.
echoes "finite double + float still bind after the guard" \
  '{"weight":2.5,"ratio":0.5}' '"weight":2.5' '"ratio":0.5'

title "6g.9 every kind at once, one request"
echoes "the full matrix round-trips in a single call" \
  '{"priceCents":"1050","signedDelta":"-42","fixedSigned":"-7","hugeCount":"18446744073709551615","fixedUnsigned":"4294967296","quantity":-3,"unsignedQuantity":9,"weight":2.5,"ratio":0.5,"active":true,"label":"widget","payload":"+/+/Pn0=","flavor":"FLAVOR_SWEET","occurredAt":"2026-08-06T12:30:00Z","amounts":["10","20"],"tags":["x","y"],"child":{"childCents":"100","childLabel":"kid"},"children":[{"childCents":"1000","childLabel":"one"}]}' \
  '"priceCents":"1050"' '"signedDelta":"-42"' '"fixedSigned":"-7"' \
  '"hugeCount":"18446744073709551615"' '"fixedUnsigned":"4294967296"' \
  '"quantity":-3' '"unsignedQuantity":9' '"weight":2.5' '"ratio":0.5' \
  '"active":true' '"label":"widget"' '"payload":"+/+/Pn0="' \
  '"flavor":"FLAVOR_SWEET"' '"occurredAt":"2026-08-06T12:30:00Z"' \
  '"amounts":\["10","20"\]' '"tags":\["x","y"\]' \
  '"childCents":"100"' '"childCents":"1000"' \
  '"sumCents":"2180"' '"labelPresent":true'

##############################################################################
sec "6h. The only_total conflict matrix + fields/orderBy vocabulary guards"
##############################################################################
# The REST wrapper rejects ?onlyTotal=true combined with any page-shaping
# control (e2e §17.5-17.9: fields/orderBy/first/last/after/before → 400 with the
# onlyTotal[<key>] marker). The gRPC criteria builder carries the SAME matrix
# — presence-based, since proto3 optional distinguishes absent from zero.
# Filter leaves, search and include_archived stay valid in count mode
# (counting a filtered subset is the canonical use case — 6c.1/6c.4/6c.5
# already prove those legs); only_total=false must behave as omitted.
# State here: carol + dave active, alice archived (all userName grpcqa_*).

conflict() { # conflict <label> <request-json> <marker>
  rpc ListUsers "$2"
  if [ "$RPC_STATUS" = "400" ] && echo "$RPC_BODY" | grep -q 'SchemaViolationNotification' \
     && echo "$RPC_BODY" | grep -qF "$3"; then
    ok "$1"
  else
    bad "$1 (status $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
  fi
}

title "6h.1 only_total + limit → invalid_argument (onlyTotal[first])"
conflict "only-total rejects first" \
  '{"pagination":{"onlyTotal":true,"first":1}}' 'onlyTotal[first]'

title "6h.2 only_total + after → invalid_argument (onlyTotal[after])"
conflict "only-total rejects after" \
  '{"pagination":{"onlyTotal":true,"after":"cur-xyz"}}' 'onlyTotal[after]'

title "6h.3 only_total + before → invalid_argument (onlyTotal[before])"
conflict "only-total rejects before" \
  '{"pagination":{"onlyTotal":true,"before":"cur-xyz"}}' 'onlyTotal[before]'

title "6h.4 only_total + orderBy → invalid_argument (onlyTotal[orderBy])"
conflict "only-total rejects orderBy" \
  '{"orderBy":[{"field":"user_name"}],"pagination":{"onlyTotal":true}}' 'onlyTotal[orderBy]'

title "6h.5 only_total + fields → invalid_argument (onlyTotal[fields])"
conflict "only-total rejects fields" \
  '{"fields":"userName","pagination":{"onlyTotal":true}}' 'onlyTotal[fields]'

# The gate's only-total matrix has SIX page-shaping keys (queryschema: fields,
# orderBy, first, last, after, before) and 6h.1-6h.5 covered five — `last` was
# the hole, and it is the one REST pins at e2e §17.9b.
title "6h.5b only_total + last → invalid_argument (onlyTotal[last])"
conflict "only-total rejects last" \
  '{"pagination":{"onlyTotal":true,"last":1}}' 'onlyTotal[last]'

title "6h.6 search stays valid in count mode (PaginationRequest.search)"
rpc ListUsers '{"pagination":{"onlyTotal":true,"search":"Dave"}}'
if [ "$RPC_STATUS" = "200" ] && echo "$RPC_BODY" | grep -Eq '"totalCount":"?1"?' \
   && ! echo "$RPC_BODY" | grep -q '"items"'; then
  ok "search + only_total counts the text-index match"
else
  bad "search+onlyTotal (status $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

title "6h.7 search in listing mode shapes the items"
rpc ListUsers '{"pagination":{"first":10,"search":"Dave"}}'
if [ "$RPC_STATUS" = "200" ] && echo "$RPC_BODY" | grep -q 'grpcqa_dave' \
   && ! echo "$RPC_BODY" | grep -q 'grpcqa_carol'; then
  ok "search selects dave only, items returned"
else
  bad "search listing (status $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

title "6h.8 only_total=false behaves as omitted (listing envelope intact)"
rpc ListUsers '{"pagination":{"onlyTotal":false,"first":1}}'
if [ "$RPC_STATUS" = "200" ] && echo "$RPC_BODY" | grep -q '"items"'; then
  ok "explicit false keeps the listing envelope (limit accepted)"
else
  bad "onlyTotal=false (status $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

title "6h.9 undeclared fields path → invalid_argument (Fields allowlist)"
rpc ListUsers '{"fields":"nope"}'
if [ "$RPC_STATUS" = "400" ] && echo "$RPC_BODY" | grep -q 'SchemaViolationNotification'; then
  ok "fields mask outside the vocabulary rejects"
else
  bad "undeclared mask (status $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

title "6h.10 undeclared orderBy field → invalid_argument (Fields allowlist)"
rpc ListUsers '{"orderBy":[{"field":"nope"}]}'
if [ "$RPC_STATUS" = "400" ] && echo "$RPC_BODY" | grep -q 'SchemaViolationNotification'; then
  ok "orderBy outside the vocabulary rejects"
else
  bad "undeclared orderBy (status $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

##############################################################################
sec "6i. Pagination REJECTION matrix — positivity, direction, ceiling, cursor"
##############################################################################
# §6c/§6f prove the happy walk and §6h the only-total conflicts, but every
# NEGATIVE pagination leg REST carries (e2e §15.5, §15.9c, §15.10-§15.15) was
# untested on this surface. Two distinct enforcement points are exercised here
# and they must not be confused:
#
#   - the canonical control gateway (queryschema.ValidateControls), shared
#     verbatim with REST and GraphQL — positivity and direction, rejected
#     BEFORE dispatch, field = the offending control key;
#   - the READER — the per-view page-size ceiling (LimitExceededNotification)
#     and cursor validity (InvalidCursorError → SchemaViolationNotification).
#     gRPC has no pre-dispatch cursor check, so these surface from the reader,
#     which is exactly why they need their own cases here.
#
# Both must land as invalid_argument with a typed notification — never a bare
# `internal`. State: carol + dave active, alice archived (userName grpcqa_*).

title "6i.1 first:0 → invalid_argument (non-positive page size)"
conflict "first:0 rejected" '{"pagination":{"first":0}}' '"field":"first"'

title "6i.2 first:-5 → invalid_argument (negative page size)"
conflict "first:-5 rejected" '{"pagination":{"first":-5}}' '"field":"first"'

title "6i.3 last:0 → invalid_argument (non-positive, backward side)"
conflict "last:0 rejected" '{"pagination":{"last":0}}' '"field":"last"'

title "6i.4 last:-5 → invalid_argument (negative, backward side)"
conflict "last:-5 rejected" '{"pagination":{"last":-5}}' '"field":"last"'

# The four direction mixes. The gate reports the BACKWARD side as the offending
# field (`last` when present, else `before`) — the same field REST puts on its
# 400 envelope, so the two surfaces name the same culprit for the same request.
title "6i.5 first + last → invalid_argument (one direction at a time)"
conflict "first+last rejected" '{"pagination":{"first":1,"last":1}}' '"field":"last"'

title "6i.6 after + before → invalid_argument (mutually exclusive cursors)"
conflict "after+before rejected" \
  '{"pagination":{"after":"cur-xyz","before":"cur-xyz"}}' '"field":"before"'

title "6i.7 last + after → invalid_argument (backward size, forward cursor)"
conflict "last+after rejected" \
  '{"pagination":{"last":1,"after":"cur-xyz"}}' '"field":"last"'

title "6i.8 first + before → invalid_argument (forward size, backward cursor)"
conflict "first+before rejected" \
  '{"pagination":{"first":1,"before":"cur-xyz"}}' '"field":"before"'

# The page-size ceiling is resolved in the reader (view MaxLimit → yaml
# query.maxLimit → framework default), so it is surface-neutral: 100 in
# microservice.qa.yaml. 100 is AT the cap, 101 the first value past it — the
# boundary pair, with the typed notification REST asserts at e2e §15.15.
title "6i.9 first:101 (one past the ceiling) → invalid_argument + LimitExceeded"
rpc ListUsers '{"pagination":{"first":101}}'
if [ "$RPC_STATUS" = "400" ] && echo "$RPC_BODY" | grep -q 'LimitExceededNotification'; then
  ok "page size past the ceiling rejects with the typed notification"
else
  bad "first:101 (status $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

title "6i.10 first:100 (exactly AT the ceiling) → 200"
rpc ListUsers '{"pagination":{"first":100}}'
if [ "$RPC_STATUS" = "200" ]; then
  ok "page size at the ceiling is accepted"
else
  bad "first:100 (status $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

title "6i.11 malformed cursor (not base64) → invalid_argument, never internal"
rpc ListUsers '{"pagination":{"first":1,"after":"not-base64---"}}'
if [ "$RPC_STATUS" = "400" ] && echo "$RPC_BODY" | grep -q 'SchemaViolationNotification' \
   && ! echo "$RPC_BODY" | grep -q '"code":"internal"'; then
  ok "undecodable cursor rejects legibly"
else
  bad "malformed cursor (status $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

# The reader binds every cursor to HashContext(filter, orderBy, search,
# includeArchived): a cursor is spendable ONLY inside the exact listing that
# issued it. Changing an axis between pages must reject rather than silently
# seek into a different result set — REST pins the three axes at e2e
# §15.16-§15.18 and they were never proven here. Each case below issues a real
# cursor in one context and spends it in a shifted one.
title "6i.12 cursor↔filter mismatch → invalid_argument"
rpc ListUsers "${GRPC_PAGE}:{\"first\":1}}"
CUR_CTX=$(echo "$RPC_BODY" | grep -o '"endCursor":"[^"]*"' | cut -d'"' -f4)
if [ -n "$CUR_CTX" ]; then
  conflict "cursor issued unfiltered-by-carol, spent with a narrowed filter" \
    "{\"filters\":{\"userName\":{\"conditions\":[{\"op\":\"STRING_OP_STARTSWITH\",\"values\":[\"grpcqa_c\"]}]}},\"orderBy\":[{\"field\":\"user_name\"}],\"pagination\":{\"first\":1,\"after\":\"$CUR_CTX\"}}" \
    'SchemaViolationNotification'
else
  bad "6i.12 could not issue a cursor"; echo "$RPC_BODY" | head -c 200; echo
fi

title "6i.13 cursor↔orderBy mismatch → invalid_argument"
rpc ListUsers '{"filters":{"userName":{"conditions":[{"op":"STRING_OP_STARTSWITH","values":["grpcqa_"]}]}},"pagination":{"first":1}}'
CUR_NOSORT=$(echo "$RPC_BODY" | grep -o '"endCursor":"[^"]*"' | cut -d'"' -f4)
if [ -n "$CUR_NOSORT" ]; then
  conflict "cursor issued unsorted, spent sorted" \
    "${GRPC_PAGE}:{\"first\":1,\"after\":\"$CUR_NOSORT\"}}" \
    'SchemaViolationNotification'
else
  bad "6i.13 could not issue an unsorted cursor"; echo "$RPC_BODY" | head -c 200; echo
fi

title "6i.14 cursor↔include_archived mismatch → invalid_argument"
if [ -n "$CUR_CTX" ]; then
  conflict "cursor issued on the default gate, spent with include_archived" \
    "${GRPC_PAGE}:{\"first\":1,\"after\":\"$CUR_CTX\",\"includeArchived\":true}}" \
    'SchemaViolationNotification'
else
  bad "6i.14 no cursor from 6i.12"
fi

##############################################################################
sec "7. Internal-plane posture — side-by-side with the main door"
##############################################################################
# Reboot with a variant config: auth.mode=jwt (PEM keypair generated here)
# + grpc.auth.mode=internal. The SAME process then rejects tokenless REST
# (401 at the main door) while tokenless gRPC passes (trusted plane).
title "7.1 Reboot with auth=jwt + grpc.auth.mode=internal"
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true
kill_port "${HTTP_PORT:-8080}"; kill_port "${GRPC_PORT:-9090}"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$POSTURE_KEY" >/dev/null 2>&1
openssl pkey -in "$POSTURE_KEY" -pubout -out "$POSTURE_KEY.pub" >/dev/null 2>&1
python3 - "$REPO_ROOT/microservice.qa.yaml" "$POSTURE_YAML" "$POSTURE_KEY.pub" <<'PYEOF2'
import sys
src, dst, pubfile = sys.argv[1], sys.argv[2], sys.argv[3]
pem = "".join("      " + line + "\n" for line in open(pubfile).read().splitlines())
s = open(src).read()
jwt_block = "auth:\n  mode: jwt\n  publicRoutes: [\"GET /livez\"]\n  jwt:\n    issuer: \"qa-posture\"\n    audience: \"qa-posture\"\n    publicKeyPem: |\n" + pem
s = s.replace("auth:\n  mode: disabled", jwt_block, 1)
s = s.replace("grpc:\n", "grpc:\n  auth:\n    mode: internal\n", 1)
open(dst, "w").write(s)
PYEOF2
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$POSTURE_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "variant booted" || { bad "variant boot failed"; tail -n 30 "$SERVER_LOG"; exit 1; }
grep -Eq '"mode":"internal"|mode=internal' "$SERVER_LOG" && ok "posture=internal logged" || bad "posture log missing"

title "7.2 Main door: tokenless REST → 401"
ST=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/users")
if [ "$ST" = "401" ]; then ok "REST rejects without token"; else bad "REST expected 401, got $ST"; fi

title "7.3 Internal plane: tokenless gRPC → passes (anonymous)"
rpc ListUsers '{"pagination":{"onlyTotal":true}}'
if [ "$RPC_STATUS" = "200" ]; then
  ok "gRPC anonymous internal call passes"
else
  bad "internal plane (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

title "7.4 Forged bearer on the internal plane → unauthenticated"
RPC_ST=$(curl -sS -o /tmp/grpc-forged.json -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" -H "Authorization: Bearer forged.garbage.token" \
  "$GRPC_BASE/users.v1.UsersService/ListUsers" -d '{}')
if [ "$RPC_ST" = "401" ] && grep -q '"code":"unauthenticated"' /tmp/grpc-forged.json; then
  ok "forged attribution rejected"
else
  bad "forged (got $RPC_ST)"; head -c 200 /tmp/grpc-forged.json; echo
fi

##############################################################################
hr
printf 'RESULT: \033[1;32mPASS=%d\033[0m \033[1;31mFAIL=%d\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
