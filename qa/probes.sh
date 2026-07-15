#!/usr/bin/env bash
# Health-probe suite — the split liveness/readiness probes (item 1 of the
# production-readiness backlog) that the canonical example never asserts in
# isolation:
#
#   /livez  — liveness. Static 200 {"status":"ok"}, NO dependency checks, ignores
#             auth/headers (it must fail only when a restart is the cure).
#   /readyz — readiness. 200 {"status":"ready"} when the request-path stores
#             answer; 503 {"status":"unavailable","reason":"relational: ..."} when
#             a store is unreachable; recovers to 200 when the store returns
#             (readiness is dynamic — re-evaluated every probe).
#
# The message TRANSPORT is deliberately EXCLUDED from readiness: the outbox
# decouples writes from the broker, so a broker outage must not pull the pod from
# the balancer. That exclusion is structural in the framework (readiness pings
# only relational + Mongo) and is NOT exercised here by stopping the shared broker
# — doing so would disrupt the parallel lane's CDC pipeline.
#
# The draining flip (SIGTERM → /readyz 503) is covered by framework unit tests
# (bootstrap.TestBuildApp_ReadyzUnavailableWhenDraining, TestReadinessCheck_*) and
# is not reliably observable black-box: graceful shutdown closes the listener
# before a fresh probe connection can be served. Here we prove the equivalent
# store-health flip + recovery, which exercises the SAME readiness.check() path.
#
# Self-managed; qa binary + microservice.qa.yaml. Dialect-driven via _backend.sh.
# The store-down step pauses THIS lane's OWN relational container ($QA_DB_CONTAINER)
# for ~1s — reversible and isolated to this lane (the sibling lane uses a different
# DB container; Mongo, which IS shared, is never touched). Same pattern cache.sh
# uses to stop/start its own Redis.
# Run from anywhere:  bash qa/probes.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-probes-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-probes-${BACKEND:-postgres}.log"

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
  # Always un-pause the lane DB, even on an early abort mid-test.
  docker --context "${QA_DOCKER_CONTEXT:-default}" unpause "$QA_DB_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# assert_status_body <name> <path> <expected_status> <body_substring> [curl-extra...]
assert_status_body() {
  local name="$1" path="$2" exp="$3" sub="$4"; shift 4
  title "$name"
  local tmp; tmp=$(mktemp)
  local st; st=$(curl -sS -m 8 -o "$tmp" -w "%{http_code}" "$BASE$path" "$@")
  local body; body=$(head -c 200 "$tmp")
  echo "GET $path → $st  $body"
  if [ "$st" = "$exp" ] && grep -q "$sub" "$tmp"; then
    ok "$name ($exp / $sub)"
  else
    bad "$name (want $exp containing '$sub', got $st)"
  fi
  rm -f "$tmp"
}

##############################################################################
sec "0. Build qa binary + boot"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"

title "0.2 Start server (config=microservice.qa.yaml)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$REPO_ROOT/microservice.qa.yaml" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }

##############################################################################
sec "1. /livez — liveness is static and dependency-free"
##############################################################################
assert_status_body "1.1 GET /livez → 200 {\"status\":\"ok\"}" \
  "/livez" 200 '"status":"ok"'

# Liveness must answer regardless of request content: it never restarts on a bad
# header, and it carries no auth/dependency logic.
assert_status_body "1.2 GET /livez with a malformed bearer + junk header → still 200" \
  "/livez" 200 '"status":"ok"' \
  -H "Authorization: Bearer not-a-jwt" -H "X-Garbage: ]]]{{{"

##############################################################################
sec "2. /readyz — readiness reflects request-path store health, dynamically"
##############################################################################
assert_status_body "2.1 GET /readyz → 200 {\"status\":\"ready\"} (stores up)" \
  "/readyz" 200 '"status":"ready"'

title "2.2 Pause the lane relational DB → /readyz 503, /livez unaffected"
# Pausing (SIGSTOP) freezes the DB so the readiness SELECT 1 times out under the
# 2s probe deadline → 503 with a "relational:" reason. Instant + reversible; the
# sibling lane uses a different container and Mongo is never touched. The lane's
# DB may live on a remote docker engine (sqlserver via QA_SQLSERVER_CONTEXT), so
# every lifecycle command rides the lane's context.
docker --context "${QA_DOCKER_CONTEXT:-default}" pause "$QA_DB_CONTAINER" >/dev/null 2>&1
sleep 1
rtmp=$(mktemp); rst=$(curl -sS -m 8 -o "$rtmp" -w "%{http_code}" "$BASE/readyz")
rbody=$(head -c 200 "$rtmp")
echo "GET /readyz (db paused) → $rst  $rbody"
if [ "$rst" = "503" ] && grep -q '"status":"unavailable"' "$rtmp" && grep -q '"reason":"relational' "$rtmp"; then
  ok "2.2a /readyz 503 unavailable (reason relational) while the store is down"
else
  bad "2.2a want 503 unavailable/relational, got $rst"
fi
rm -f "$rtmp"
# Liveness must stay green while readiness is red — a store blip is NOT a restart
# reason.
ltmp=$(mktemp); lst=$(curl -sS -m 8 -o "$ltmp" -w "%{http_code}" "$BASE/livez")
echo "GET /livez (db paused) → $lst  $(head -c 80 "$ltmp")"
if [ "$lst" = "200" ] && grep -q '"status":"ok"' "$ltmp"; then
  ok "2.2b /livez stays 200 while /readyz is 503 (store blip ≠ restart)"
else
  bad "2.2b want /livez 200 during the store outage, got $lst"
fi
rm -f "$ltmp"

title "2.3 Un-pause the DB → /readyz recovers to 200 (readiness is dynamic)"
docker --context "${QA_DOCKER_CONTEXT:-default}" unpause "$QA_DB_CONTAINER" >/dev/null 2>&1
recovered=fail
for _i in $(seq 1 20); do
  st=$(curl -sS -m 4 -o /dev/null -w "%{http_code}" "$BASE/readyz" 2>/dev/null)
  [ "$st" = "200" ] && { recovered=ok; break; }
  sleep 0.5
done
if [ "$recovered" = ok ]; then
  ok "2.3 /readyz recovered to 200 once the store returned"
else
  bad "2.3 /readyz never recovered after un-pausing the DB"
fi

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
