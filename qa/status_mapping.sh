#!/usr/bin/env bash
# HTTP status-mapping suite — the Semantic → HTTP codes the canonical example
# never exercises. status-mapping.html documents 405/413/500/503/504 among
# others; e2e §20 covers 404/405, and the write suites cover 422/400/409. This
# closes the residual four:
#
#   413 PayloadTooLargeNotification   — body over Fiber's default BodyLimit (4MB)
#   500 InternalServerErrorNotification — a panic recovered by fwweb.Recover()
#   503 ServiceUnavailableNotification — a handler emitting SemanticUnavailable
#
# 500/503 ride qa-only showcase routes on the Gadget mirror (`//go:build qa`,
# /qa/showcase/*). 504 (RequestTimeoutNotification) is intentionally NOT covered
# here: the framework's http.requestTimeoutSeconds deadline reaches the
# downstream I/O (pgx/mongo/httpclient) via the repository/query ctx, not via a
# handler that polls AppContext.Done() — so a synthetic sleep handler cannot
# reproduce it. The deadline→504 mapping is unit-tested in the framework
# (pipeline.Run maps context.DeadlineExceeded; app_context sets the deadline).
#
# Self-managed; qa binary + microservice.qa.yaml. Dialect-driven via _backend.sh.
# Run from anywhere:  bash qa/status_mapping.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-status-mapping"
SERVER_LOG="/tmp/omnicore-example-users-qa-status-mapping.log"
LOW_TIMEOUT_YAML="/tmp/omnicore-qa-lowtimeout.yaml"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port 8080; rm -f "$LOW_TIMEOUT_YAML"
  qa_db_exec "DELETE FROM gadgets;" 2>/dev/null || true
  docker exec omnicore-example-mongo mongosh "$QA_MONGO_DB" --quiet --eval 'db.gadgets.drop(); db.gadget_notes.drop(); db.gadgets_hot.drop(); db.gadgets_capped.drop(); db.upstream_gadgets.drop()' >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# assert_status_key <name> <method> <path> <expected_status> <expected_key> [curl-extra...]
assert_status_key() {
  local name="$1" method="$2" path="$3" exp="$4" key="$5"; shift 5
  title "$name"
  local tmp; tmp=$(mktemp)
  local st; st=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" "$@")
  local got; got=$(grep -o "\"notificationKey\":\"[^\"]*\"" "$tmp" | head -1)
  echo "$method $path → $st  $got"
  if [ "$st" = "$exp" ] && grep -q "\"notificationKey\":\"$key\"" "$tmp"; then
    ok "$name ($exp / $key)"
  else
    bad "$name (want $exp / $key, got $st)"; head -c 300 "$tmp"; echo
  fi
  rm -f "$tmp"
}

##############################################################################
sec "0. Build qa binary + boot"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port 8080

title "0.2 Start server (config=microservice.qa.yaml)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$REPO_ROOT/microservice.qa.yaml" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/health" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }

##############################################################################
sec "1. 500 — a recovered panic"
##############################################################################
assert_status_key "1.1 GET /qa/showcase/panic → 500 InternalServerErrorNotification" \
  GET "/qa/showcase/panic" 500 "InternalServerErrorNotification"

##############################################################################
sec "2. 503 — ServiceUnavailableNotification"
##############################################################################
assert_status_key "2.1 GET /qa/showcase/unavailable → 503 ServiceUnavailableNotification" \
  GET "/qa/showcase/unavailable" 503 "ServiceUnavailableNotification"

##############################################################################
sec "3. 413 — request body over the BodyLimit (Fiber default 4MB)"
##############################################################################
# The framework leaves Fiber's default 4MB BodyLimit in place; a larger body is
# rejected by the router before the handler, and the ErrorHandler maps Fiber's
# 413 to PayloadTooLargeNotification.
title "3.1 POST /qa/gadgets with a ~5MB body → 413 PayloadTooLargeNotification"
# Expect: 100-continue makes curl send headers first and wait for the verdict:
# the server sees Content-Length over the 4MB BodyLimit and answers 413 WITHOUT
# the body, so curl reads the 413 instead of racing an oversized upload against
# an early server response (which surfaces as a connection reset).
BIG=$(mktemp)
{ printf '{"code":"BIG","name":"'; head -c 5000000 /dev/zero | tr '\0' 'A'; printf '","category":"c","status":"active"}'; } > "$BIG"
tmp=$(mktemp)
# Retried: under load the server occasionally sends 100 Continue and then
# resets the connection mid-upload (curl exit 55, http_code 100) — a transport
# race, not the mapping under test. A real 413 regression fails all attempts.
st=""
for _try in 1 2 3; do
  st=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST "$BASE/qa/gadgets" \
    -H "Content-Type: application/json" -H "Expect: 100-continue" --expect100-timeout 5 \
    --data-binary @"$BIG") || true
  [ "$st" = "413" ] && break
  sleep 1
done
got=$(grep -o '"notificationKey":"[^"]*"' "$tmp" | head -1)
echo "POST ~5MB → $st  $got"
if [ "$st" = "413" ] && grep -q '"notificationKey":"PayloadTooLargeNotification"' "$tmp"; then
  ok "3.1 oversized body rejected (413 / PayloadTooLargeNotification)"
else
  bad "3.1 want 413 / PayloadTooLargeNotification, got $st"; head -c 200 "$tmp"; echo
fi
rm -f "$BIG" "$tmp"

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
