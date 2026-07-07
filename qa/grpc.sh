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
#
# Self-managed; qa binary + microservice.qa.yaml. Dialect-driven via
# _backend.sh. Run from anywhere:  bash qa/grpc.sh
set -u

BASE="${BASE:-http://localhost:8080}"
GRPC_BASE="${GRPC_BASE:-http://localhost:9090}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-grpc"
SERVER_LOG="/tmp/omnicore-example-users-qa-grpc.log"
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
  kill_port 8080; kill_port 9090
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
kill_port 8080; kill_port 9090

title "0.2 Reset bench (relational domain tables + Mongo users view)"
qa_db_reset_domain
qa_mongo_reset
sleep 2

title "0.3 Start server (config=microservice.qa.yaml)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$REPO_ROOT/microservice.qa.yaml" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/health" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "http ready" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }
grep -q "grpc listening" "$SERVER_LOG" && ok "grpc listener up (:9090)" || { bad "grpc listener missing in log"; tail -n 30 "$SERVER_LOG"; exit 1; }

##############################################################################
sec "1. CreateUser — happy path"
##############################################################################
title "1.1 CreateUser → 200 with assigned id"
rpc CreateUser '{"name":"Grpc Alice","email":"grpc.alice@example.com","document":"99091000001","userName":"grpcqa_alice","phone":"14155550001"}'
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
rpc CreateUser '{"name":"","email":"grpc.bad@example.com","document":"99091000002","userName":"grpcqa_bad"}'
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
rpc CreateUser '{"name":"Grpc Alice","email":"grpc.alice@example.com","document":"99091000001","userName":"grpcqa_alice"}'
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
  echo "$RPC_BODY" | grep -q '"total":"1"\|"total":1' && { found=ok; break; }
  sleep 0.5
done
echo "status=$RPC_STATUS body=${RPC_BODY:0:200}"
if [ "$found" = ok ] && echo "$RPC_BODY" | grep -q '"userName":"grpcqa_alice"'; then
  ok "equality filter + projected item"
else
  bad "ListUsers filter"; echo "$RPC_BODY" | head -c 400; echo
fi

title "4.2 only_total → total without items"
rpc ListUsers '{"page":{"onlyTotal":true}}'
if [ "$RPC_STATUS" = "200" ] && ! echo "$RPC_BODY" | grep -q '"items"'; then
  ok "only_total suppresses items"
else
  bad "only_total (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

title "4.3 contains filter + sort + read_mask (shared omnicore.v1 components)"
rpc ListUsers '{"filters":{"userName":{"conditions":[{"op":"STRING_OP_CONTAINS","values":["grpcqa"]}]}},"sort":[{"field":"user_name","desc":true}],"readMask":"id,userName"}'
echo "status=$RPC_STATUS body=${RPC_BODY:0:200}"
if [ "$RPC_STATUS" = "200" ] && echo "$RPC_BODY" | grep -q '"userName":"grpcqa_alice"' \
   && ! echo "$RPC_BODY" | grep -q '"email"'; then
  ok "contains + sort + read_mask projection (email masked out)"
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
rpc CreateUser '{"name":"Grpc Carol","email":"grpc.carol@example.com","document":"99091000003","userName":"grpcqa_carol"}'
CAROL_ID=$(echo "$RPC_BODY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
[ -n "$CAROL_ID" ] && ok "carol created" || { bad "carol create"; echo "$RPC_BODY" | head -c 300; }

title "6b.2 UpdateUser full body → 200 with the new values"
rpc UpdateUser "{\"id\":\"$CAROL_ID\",\"name\":\"Carol Renamed\",\"email\":\"carol.renamed@example.com\",\"userName\":\"grpcqa_carol\",\"addresses\":[]}"
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
rpc UpdateUser '{"id":"00000000-0000-0000-0000-000000000000","name":"X","email":"x@example.com","userName":"ghost","addresses":[]}'
if [ "$RPC_STATUS" = "404" ] && echo "$RPC_BODY" | grep -q '"code":"not_found"'; then
  ok "unknown id → not_found"
else
  bad "unknown id (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

##############################################################################
sec "6c. Pagination + filter vocabulary over the shared components"
##############################################################################
title "6c.1 seed dave (poll list until both project)"
rpc CreateUser '{"name":"Grpc Dave","email":"grpc.dave@example.com","document":"99091000004","userName":"grpcqa_dave"}'
deadline=$(( $(date +%s) + 15 )); seeded=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  rpc ListUsers '{"filters":{"userName":{"conditions":[{"op":"STRING_OP_STARTSWITH","values":["grpcqa_"]}]}},"page":{"onlyTotal":true}}'
  echo "$RPC_BODY" | grep -Eq '"total":"?2"?' && { seeded=ok; break; }
  sleep 0.5
done
[ "$seeded" = ok ] && ok "carol + dave projected (alice hidden as archived)" || { bad "seeding"; echo "$RPC_BODY" | head -c 200; }

title "6c.2 page 1: sort userName asc, limit 1 → carol + nextCursor"
rpc ListUsers '{"filters":{"userName":{"conditions":[{"op":"STRING_OP_STARTSWITH","values":["grpcqa_"]}]}},"sort":[{"field":"user_name"}],"page":{"limit":1}}'
CURSOR=$(echo "$RPC_BODY" | grep -o '"nextCursor":"[^"]*"' | cut -d'"' -f4)
if echo "$RPC_BODY" | grep -q '"userName":"grpcqa_carol"' && [ -n "$CURSOR" ]; then
  ok "page 1 = carol, cursor issued"
else
  bad "page 1"; echo "$RPC_BODY" | head -c 300; echo
fi

title "6c.3 page 2: after=cursor → dave"
rpc ListUsers "{\"filters\":{\"userName\":{\"conditions\":[{\"op\":\"STRING_OP_STARTSWITH\",\"values\":[\"grpcqa_\"]}]}},\"sort\":[{\"field\":\"user_name\"}],\"page\":{\"limit\":1,\"after\":\"$CURSOR\"}}"
if echo "$RPC_BODY" | grep -q '"userName":"grpcqa_dave"' && ! echo "$RPC_BODY" | grep -q 'grpcqa_carol'; then
  ok "cursor walk reaches dave only"
else
  bad "page 2"; echo "$RPC_BODY" | head -c 300; echo
fi

title "6c.4 IN filter with multiple values"
rpc ListUsers '{"filters":{"userName":{"conditions":[{"op":"STRING_OP_IN","values":["grpcqa_carol","grpcqa_dave"]}]}},"page":{"onlyTotal":true}}'
if echo "$RPC_BODY" | grep -Eq '"total":"?2"?'; then ok "IN matches both"; else bad "IN"; echo "$RPC_BODY" | head -c 200; fi

title "6c.5 include_archived resurfaces alice in the count"
rpc ListUsers '{"filters":{"userName":{"conditions":[{"op":"STRING_OP_STARTSWITH","values":["grpcqa_"]}]}},"page":{"onlyTotal":true,"includeArchived":true}}'
if echo "$RPC_BODY" | grep -Eq '"total":"?3"?'; then ok "archived included on opt-in"; else bad "includeArchived"; echo "$RPC_BODY" | head -c 200; fi

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
    -d "{\"filters\":{\"$1\":{\"conditions\":[{\"op\":\"$2\",\"values\":$3}]}},\"page\":{\"onlyTotal\":true}}" \
    | grep -o '"total":"\{0,1\}[0-9]*' | grep -o '[0-9]*$'
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
check_op ne          category STRING_OP_NE          '["tools"]'             1
check_op in          code     STRING_OP_IN          '["ALPHA-1","GAMMA-3"]' 2
check_op nin         status   STRING_OP_NIN         '["active"]'            1
check_op startswith  name     STRING_OP_STARTSWITH  '["Rocket"]'            2
check_op contains    name     STRING_OP_CONTAINS    '["ck"]'                2
check_op ieq         name     STRING_OP_IEQ         '["hammer"]'            1
check_op ine         name     STRING_OP_INE         '["hammer"]'            2
check_op istartswith name     STRING_OP_ISTARTSWITH '["rock"]'              2
check_op icontains   name     STRING_OP_ICONTAINS   '["CK"]'                2
check_op iin         category STRING_OP_IIN         '["TOOLS"]'             2
check_op inin        category STRING_OP_ININ        '["TOOLS"]'             1
[ "$OPS_OK" = "12" ] && ok "12/12 StringOps behave like the REST vocabulary" || bad "operator vocabulary ($OPS_OK/12)"

title "6e.3 two ops on the same field AND-combine (MultiClause)"
RES=$(curl -sS -X POST -H "Content-Type: application/json" \
  "$GRPC_BASE/qafixtures.v1.QAService/ListGadgets" \
  -d '{"filters":{"name":{"conditions":[{"op":"STRING_OP_STARTSWITH","values":["Rocket"]},{"op":"STRING_OP_ICONTAINS","values":["DRILL"]}]}},"page":{"onlyTotal":true}}')
echo "$RES" | grep -Eq '"total":"?1"?' && ok "AND-combined conditions" || { bad "MultiClause"; echo "$RES" | head -c 200; }

##############################################################################
sec "6f. Backward pagination (before + prev_cursor)"
##############################################################################
title "6f.1 walk forward to dave, then back to carol via prevCursor"
rpc ListUsers '{"filters":{"userName":{"conditions":[{"op":"STRING_OP_STARTSWITH","values":["grpcqa_"]}]}},"sort":[{"field":"user_name"}],"page":{"limit":1}}'
CUR_F=$(echo "$RPC_BODY" | grep -o '"nextCursor":"[^"]*"' | cut -d'"' -f4)
rpc ListUsers "{\"filters\":{\"userName\":{\"conditions\":[{\"op\":\"STRING_OP_STARTSWITH\",\"values\":[\"grpcqa_\"]}]}},\"sort\":[{\"field\":\"user_name\"}],\"page\":{\"limit\":1,\"after\":\"$CUR_F\"}}"
CUR_B=$(echo "$RPC_BODY" | grep -o '"prevCursor":"[^"]*"' | cut -d'"' -f4)
if [ -n "$CUR_B" ] && echo "$RPC_BODY" | grep -q 'grpcqa_dave'; then
  rpc ListUsers "{\"filters\":{\"userName\":{\"conditions\":[{\"op\":\"STRING_OP_STARTSWITH\",\"values\":[\"grpcqa_\"]}]}},\"sort\":[{\"field\":\"user_name\"}],\"page\":{\"limit\":1,\"before\":\"$CUR_B\"}}"
  if echo "$RPC_BODY" | grep -q 'grpcqa_carol' && ! echo "$RPC_BODY" | grep -q 'grpcqa_dave'; then
    ok "before-cursor walks back to carol"
  else
    bad "backward walk"; echo "$RPC_BODY" | head -c 300; echo
  fi
else
  bad "prevCursor missing on page 2"; echo "$RPC_BODY" | head -c 300; echo
fi

##############################################################################
sec "7. Internal-plane posture — side-by-side with the main door"
##############################################################################
# Reboot with a variant config: auth.mode=jwt (PEM keypair generated here)
# + grpc.auth.mode=internal. The SAME process then rejects tokenless REST
# (401 at the main door) while tokenless gRPC passes (trusted plane).
title "7.1 Reboot with auth=jwt + grpc.auth.mode=internal"
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true
kill_port 8080; kill_port 9090
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$POSTURE_KEY" >/dev/null 2>&1
openssl pkey -in "$POSTURE_KEY" -pubout -out "$POSTURE_KEY.pub" >/dev/null 2>&1
python3 - "$REPO_ROOT/microservice.qa.yaml" "$POSTURE_YAML" "$POSTURE_KEY.pub" <<'PYEOF2'
import sys
src, dst, pubfile = sys.argv[1], sys.argv[2], sys.argv[3]
pem = "".join("      " + line + "\n" for line in open(pubfile).read().splitlines())
s = open(src).read()
jwt_block = "auth:\n  mode: jwt\n  publicRoutes: [\"GET /health\"]\n  jwt:\n    issuer: \"qa-posture\"\n    audience: \"qa-posture\"\n    publicKeyPem: |\n" + pem
s = s.replace("auth:\n  mode: disabled", jwt_block, 1)
s = s.replace("grpc:\n", "grpc:\n  auth:\n    mode: internal\n", 1)
open(dst, "w").write(s)
PYEOF2
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$POSTURE_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/health" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "variant booted" || { bad "variant boot failed"; tail -n 30 "$SERVER_LOG"; exit 1; }
grep -Eq '"mode":"internal"|mode=internal' "$SERVER_LOG" && ok "posture=internal logged" || bad "posture log missing"

title "7.2 Main door: tokenless REST → 401"
ST=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/users")
if [ "$ST" = "401" ]; then ok "REST rejects without token"; else bad "REST expected 401, got $ST"; fi

title "7.3 Internal plane: tokenless gRPC → passes (anonymous)"
rpc ListUsers '{"page":{"onlyTotal":true}}'
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
