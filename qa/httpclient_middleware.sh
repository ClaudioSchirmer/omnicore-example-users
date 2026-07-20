#!/usr/bin/env bash
# Outbound httpclient — advanced middleware suite.
#
# httpclient.sh covers the core (tag binding, oauth2, streaming, multipart, SSE,
# HMAC, inline auth). This closes the middleware the canonical example never
# exercises, via a qa-only self-call showcase (`//go:build qa`): the qa binary
# serves the /qa/echo/* upstream AND calls it back through the framework's
# httpclient with these features configured in microservice.qa.yaml:
#
#   retry backoff     — flaky endpoint (503 twice) recovered within one Call
#   circuit breaker   — always-503 endpoint opens the breaker after N failures
#   idempotency key    — the client attaches X-Idempotency-Key (source: ctx)
#   XML request codec — a struct serialized as XML on the wire
#   static auth provider + header cascade + per-call WithExtraHeader
#
# Self-managed; qa binary + microservice.qa.yaml. ECHO_URL points back at the
# same server, so no external upstream is needed. Dialect-driven via _backend.sh.
# Run from anywhere:  bash qa/httpclient_middleware.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-httpclient-mw-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-httpclient-mw-${BACKEND:-postgres}.log"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
cleanup() { if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi; kill_port "${HTTP_PORT:-8080}"; qa_view_drop gadgets gadget_notes gadgets_hot gadgets_capped upstream_gadgets; }
trap cleanup EXIT INT TERM

# jget <path> <python-expr-on d.data> — GET a showcase route, print the value of
# the given python expression evaluated against the envelope's `data` object.
jget() { curl -sS "$BASE$1" | python3 -c "import sys,json
try:
  d=json.load(sys.stdin).get('data',{}); print($2)
except Exception: print('')" 2>/dev/null; }

##############################################################################
sec "0. Build qa binary + boot (config=microservice.qa.yaml)"
##############################################################################
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$REPO_ROOT/microservice.qa.yaml" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }

##############################################################################
sec "1. Retry backoff — a flaky upstream recovers within one Call"
##############################################################################
# The flaky upstream returns 503 for the first failFor calls of a key, then 200.
# The endpoint declares retry {retryOn: [503], maxAttempts: 3}, so a single Call
# fails twice and succeeds on the third attempt — the client replays the request.
title "1.1 GET /qa/showcase/httpclient/retry?failFor=2 → attempts=3, recovered"
ATT=$(jget "/qa/showcase/httpclient/retry?key=qa-retry-$$&failFor=2" "d.get('attempts')")
REC=$(jget "/qa/showcase/httpclient/retry?key=qa-retry2-$$&failFor=2" "d.get('recovered')")
echo "attempts=$ATT recovered=$REC"
[ "$ATT" = "3" ] && ok "recovered on the 3rd attempt (2 retries of a 503)" || bad "attempts=$ATT (want 3)"
[ "$REC" = "True" ] && ok "the Call reports recovered=true" || bad "recovered=$REC (want True)"

##############################################################################
sec "2. Circuit breaker — repeated failures open the breaker"
##############################################################################
# always500 always returns 503 (no retry). With failureThreshold=3, calls 1-3
# fail against the upstream and call 4+ short-circuits with ErrCircuitOpen — the
# showcase loops failureThreshold+2 times and reports the open state.
title "2.1 GET /qa/showcase/httpclient/breaker → tripped, lastError='circuit open'"
BODY=$(curl -sS "$BASE/qa/showcase/httpclient/breaker")
TRIP=$(echo "$BODY" | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('tripped'))" 2>/dev/null)
LERR=$(echo "$BODY" | python3 -c "import sys,json;print(json.load(sys.stdin).get('data',{}).get('lastError'))" 2>/dev/null)
echo "tripped=$TRIP lastError=$LERR"
[ "$TRIP" = "True" ] && ok "the breaker tripped after the failure threshold" || bad "tripped=$TRIP (want True)"
echo "$LERR" | grep -qi "circuit open" && ok "the short-circuit surfaces ErrCircuitOpen ('circuit open')" || bad "lastError=$LERR (want circuit open)"

##############################################################################
sec "3. Idempotency — the client attaches X-Idempotency-Key (source: ctx)"
##############################################################################
title "3.1 GET /qa/showcase/httpclient/idempotency → non-empty idempotencyKey echoed"
KEY=$(jget "/qa/showcase/httpclient/idempotency" "d.get('idempotencyKey','')")
echo "idempotencyKey=$KEY"
if [ -n "$KEY" ] && [ "$KEY" != "None" ]; then
  ok "the upstream echoed a non-empty X-Idempotency-Key (client-attached from ctx)"
else
  bad "no idempotency key attached (got '$KEY')"
fi

##############################################################################
sec "4. XML request codec — a struct serialized as XML on the wire"
##############################################################################
title "4.1 GET /qa/showcase/httpclient/xml?code=OMNI → echoed=OMNI"
ECH=$(jget "/qa/showcase/httpclient/xml?code=OMNI" "d.get('echoed','')")
echo "echoed=$ECH"
[ "$ECH" = "OMNI" ] && ok "the XML body round-tripped (requestCodec: xml)" || bad "echoed=$ECH (want OMNI)"

##############################################################################
sec "5. Static auth provider + header cascade + per-call WithExtraHeader"
##############################################################################
title "5.1 GET /qa/showcase/httpclient/headers → bearer-static + X-Api-Key + X-Extra"
AUTH=$(jget "/qa/showcase/httpclient/headers?extra=qa-extra-val" "d.get('authorization','')")
APIK=$(jget "/qa/showcase/httpclient/headers?extra=qa-extra-val" "d.get('xApiKey','')")
XEXT=$(jget "/qa/showcase/httpclient/headers?extra=qa-extra-val" "d.get('xExtra','')")
echo "authorization=$AUTH  xApiKey=$APIK  xExtra=$XEXT"
[ "$AUTH" = "Bearer qa-demo-bearer-token" ] && ok "bearer-static provider attached Authorization: Bearer <token>" || bad "authorization=$AUTH"
[ "$APIK" = "qa-static-api-key" ] && ok "the YAML service header cascade attached X-Api-Key" || bad "xApiKey=$APIK"
[ "$XEXT" = "qa-extra-val" ] && ok "WithExtraHeader injected the per-call X-Extra" || bad "xExtra=$XEXT"

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
