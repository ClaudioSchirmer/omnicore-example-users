#!/usr/bin/env bash
# grpcclient suite — the outbound gRPC toolbox (Deps.GRPCClient, yaml
# `grpcClient:` block). The qa binary calls ITSELF over the loopback gRPC
# listener through the full client chain (correlation → auth → idempotency →
# deadline → logging → retry → breaker), exposed via the qa-only showcase:
#
#   GET /qa/showcase/grpcclient/users/:id  → GetUser via grpcclient
#   GET /qa/showcase/grpcclient/users      → ListUsers via grpcclient
#
# Retry/breaker/idempotency mechanics are unit-locked in the framework
# (infra/grpcclient, infra/resilience); this suite proves the yaml plumbing,
# the Deps exposure and the e2e loop REST → grpcclient → gRPC listener →
# the same application handlers.
#
# Self-managed; qa binary + microservice.qa.yaml. Run: bash qa/grpcclient.sh
set -u

BASE="${BASE:-http://localhost:8080}"
GRPC_BASE="${GRPC_BASE:-http://localhost:9090}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-grpcclient"
SERVER_LOG="/tmp/omnicore-example-users-qa-grpcclient.log"

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
}
trap cleanup EXIT INT TERM

##############################################################################
sec "0. Build qa binary + boot"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port 8080; kill_port 9090

title "0.2 Reset bench"
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
grep -q "grpcclient configured" "$SERVER_LOG" && ok "grpcclient configured from yaml" || { bad "grpcclient block not loaded"; exit 1; }

##############################################################################
sec "1. Seed a user over the gRPC surface"
##############################################################################
title "1.1 CreateUser (:9090)"
BODY=$(curl -sS -X POST -H "Content-Type: application/json" \
  "$GRPC_BASE/users.v1.UsersService/CreateUser" \
  -d '{"name":"GrpcClient Bob","email":"grpcc.bob@example.com","document":"99092000001","userName":"grpcqa_bob"}')
USER_ID=$(echo "$BODY" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$USER_ID" ]; then ok "user created ($USER_ID)"; else bad "create failed"; echo "$BODY" | head -c 300; exit 1; fi

##############################################################################
sec "2. REST → grpcclient → own gRPC listener"
##############################################################################
title "2.1 GET /qa/showcase/grpcclient/users/:id → via grpcclient (poll: projection async)"
deadline=$(( $(date +%s) + 15 )); found=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  RES=$(curl -sS "$BASE/qa/showcase/grpcclient/users/$USER_ID")
  echo "$RES" | grep -q '"userName":"grpcqa_bob"' && { found=ok; break; }
  sleep 0.5
done
echo "body=${RES:0:160}"
if [ "$found" = ok ] && echo "$RES" | grep -q '"via":"grpcclient"'; then
  ok "GetUser through the outbound chain"
else
  bad "showcase get"; echo "$RES" | head -c 300; echo
fi

title "2.2 List with equality filter through the chain"
RES=$(curl -sS "$BASE/qa/showcase/grpcclient/users?userName=grpcqa_bob")
if echo "$RES" | grep -q '"total":1' && echo "$RES" | grep -q 'grpcqa_bob'; then
  ok "ListUsers through the outbound chain"
else
  bad "showcase list"; echo "$RES" | head -c 300; echo
fi

title "2.3 Unknown id → client-side not_found classification (404)"
ST=$(curl -sS -o /tmp/grpcc-nf.json -w "%{http_code}" "$BASE/qa/showcase/grpcclient/users/00000000-0000-0000-0000-000000000000")
if [ "$ST" = "404" ] && grep -q '"code":"not_found"' /tmp/grpcc-nf.json; then
  ok "not_found classified through the client"
else
  bad "unknown id (got $ST)"; head -c 200 /tmp/grpcc-nf.json; echo
fi

title "2.4 Client observability: slog line per outbound call"
if grep -q "grpcclient call" "$SERVER_LOG" && grep -Eq '"service":"self-users"|service=self-users' "$SERVER_LOG"; then
  ok "grpcclient call logged with service label"
else
  bad "grpcclient log line missing"; grep -i grpc "$SERVER_LOG" | tail -3
fi

##############################################################################
sec "3. Client resilience — deterministic fixtures"
##############################################################################
title "3.1 retry recovers: fail 2x then succeed → attempts=3 through the chain"
RES=$(curl -sS "$BASE/qa/showcase/grpcclient/flaky?key=retry-$$&fail=2")
if echo "$RES" | grep -q '"attempts":3'; then
  ok "retry budget consumed exactly (3 attempts)"
else
  bad "retry (got: $RES)"
fi

title "3.2 idempotency key stable across the retried attempts"
if echo "$RES" | grep -q '"distinctKeys":1'; then
  ok "one key across 3 attempts"
else
  bad "idempotency (got: $RES)"
fi

title "3.3 breaker opens after the threshold and rejects without dialing"
curl -sS -o /dev/null "$BASE/qa/showcase/grpcclient/boom"
curl -sS -o /dev/null "$BASE/qa/showcase/grpcclient/boom"
RES=$(curl -sS "$BASE/qa/showcase/grpcclient/boom")
if echo "$RES" | grep -q "circuit breaker open"; then
  ok "breaker open surfaced to the caller"
else
  bad "breaker (got: $RES)"
fi

##############################################################################
hr
printf 'RESULT: \033[1;32mPASS=%d\033[0m \033[1;31mFAIL=%d\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
