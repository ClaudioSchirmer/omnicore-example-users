#!/usr/bin/env bash
# qa/cache.sh — end-to-end validation of the framework's cache subsystem
# (`omnicore/infra/cache`) under
# OMNICORE_CONFIG_PATH=microservice.dev-redis-cache.yaml. The YAML
# declares BOTH `cache:` (private — Deps.Cache) AND `cache.shared:`
# (cross-service — Deps.SharedCache); both back onto the same Redis
# container with distinct keyPrefix segments so the two namespaces stay
# observably separated at the backend layer.
#
# What this suite covers:
#   * Backend reachability — docker compose exec redis-cli PING
#   * /showcase/cache/info — both Deps.Cache and Deps.SharedCache wired
#   * Private cache CRUD (Set / Get / Delete / GET-after-Delete / TTL)
#   * Shared  cache CRUD (Set / Get / Delete / GET-after-Delete)
#   * Key-prefix separation observed via redis-cli KEYS
#   * httpclient response cache delegates to Deps.Cache — the framework's
#     own /showcase/keycloak/realm warm path lands under the SAME private
#     prefix, proving httpclient consumes the subsystem
#   * Cross-process persistence — kill server, restart, entries survive
#     in BOTH private and shared
#   * failOpen — stop Redis, requests still succeed (Set degrades to
#     no-op, Get to miss) and the slog records cache.redis.transport.error
#   * Restart Redis at the end; cleanup trap guarantees it on early exit
#
# Prerequisites:
#   docker compose -f devops/docker-compose.yml up -d
#   ./devops/debezium/register-connector.sh
#
# Self-managed lifecycle — the script builds the binary, starts the
# server itself, waits /health, kills it on cleanup. The operator does
# NOT keep a server running in another terminal.
#
# Each case prints REQUEST/STATUS/PASS|FAIL. Exits non-zero on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="docker compose -f $REPO_ROOT/devops/docker-compose.yml"
BASE="${BASE:-http://localhost:8080}"
SERVER_BIN="${SERVER_BIN:-/tmp/omnicore-example-users-qa-cache-bin}"
PRIVATE_PREFIX="${REDIS_KEY_PREFIX:-omnicore-example-users-cache}"
SHARED_PREFIX="${SHARED_REDIS_KEY_PREFIX:-omnicore-example-users-shared}"
REDIS_STOPPED=0
SERVER_PID=""
SERVER_LOG="/tmp/omnicore-example-users-qa-cache.log"

RED=$'\e[1;31m'
GREEN=$'\e[1;32m'
YELLOW=$'\e[1;33m'
WHITE=$'\e[1;37m'
CYAN=$'\e[1;36m'
RESET=$'\e[0m'

PASS=0
FAIL=0

hr() { printf '\n%s%s%s\n' "$CYAN" "============================================================" "$RESET"; }
sec() { hr; printf '%s== %s ==%s\n' "$YELLOW" "$1" "$RESET"; }
title() { printf '\n%s--- %s ---%s\n' "$WHITE" "$1" "$RESET"; }
pass() { echo "${GREEN}PASS${RESET}${1:+ — $1}"; PASS=$((PASS + 1)); }
fail() { echo "${RED}FAIL${RESET}${1:+ — $1}"; FAIL=$((FAIL + 1)); }

# kill_port <port>
# Frees the TCP port by sending SIGTERM, then SIGKILL, to whoever is
# listening. Same primitive as auth.sh / audit.sh.
kill_port() {
    local port="$1"
    local pids
    pids=$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
    if [ -n "$pids" ]; then
        kill $pids 2>/dev/null || true
        sleep 1
        pids=$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
        if [ -n "$pids" ]; then
            kill -9 $pids 2>/dev/null || true
        fi
    fi
}

# cleanup fires via EXIT/INT/TERM so any early exit still restores the
# side effects: the running server and the Redis container.
cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    kill_port 8080
    if [ "$REDIS_STOPPED" = "1" ]; then
        $COMPOSE start redis >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

wait_for_health() {
    local timeout="${1:-30}"
    local deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -sf -o /dev/null "$BASE/health"; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# start_server boots under APP_PROFILE=dev + OMNICORE_CONFIG_PATH so the
# framework's auth.mode=disabled guard keeps holding without forcing JWT
# infrastructure. Append (not truncate) the log so case 8's second boot
# joins the first boot's lines.
start_server() {
    kill_port 8080
    (
        cd "$REPO_ROOT"
        APP_PROFILE=dev OMNICORE_CONFIG_PATH="$REPO_ROOT/microservice.dev-redis-cache.yaml" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1
    ) &
    SERVER_PID=$!
    if ! wait_for_health 30; then
        echo "ERROR: server did not become ready in 30s" >&2
        echo "--- last 40 lines of $SERVER_LOG ---" >&2
        tail -n 40 "$SERVER_LOG" >&2
        return 1
    fi
}

stop_server() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
    fi
    kill_port 8080
}

# redis_cli wraps docker compose exec so the host doesn't need redis-cli
# installed.
redis_cli() {
    $COMPOSE exec -T redis redis-cli "$@"
}

# json_get pipes stdin through python's json.tool to pretty-print or
# fallback to raw cat. Used only for debug output on FAIL.
json_get() {
    python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('$1'))" 2>/dev/null
}

# ------------------------------------------------------------------
sec "qa/cache.sh"
# ------------------------------------------------------------------

title "0. Preconditions"
if ! $COMPOSE ps --status running --format '{{.Name}}' | grep -q omnicore-example-redis; then
    echo "Redis container not running. Bring it up first:"
    echo "  $COMPOSE up -d redis"
    exit 1
fi
if ! $COMPOSE ps --status running --format '{{.Name}}' | grep -q omnicore-example-keycloak; then
    echo "Keycloak container not running (case 7 needs it). Bring it up first:"
    echo "  $COMPOSE up -d keycloak"
    exit 1
fi

title "0.1 Build server binary"
(cd "$REPO_ROOT" && go build -tags postgres -o "$SERVER_BIN" ./bootstrap)
echo "Binary: $SERVER_BIN"

title "0.2 Reset state (Redis FLUSHDB + log file)"
redis_cli FLUSHDB >/dev/null
: > "$SERVER_LOG"
echo "Redis flushed; log $SERVER_LOG truncated"

title "0.3 Free port 8080 + start server"
kill_port 8080
if ! start_server; then
    echo "Cannot start server — aborting"
    exit 1
fi
echo "Server ready (PID=$SERVER_PID, profile=dev-redis-cache)"

# ------------------------------------------------------------------
sec "Cache subsystem cases"
# ------------------------------------------------------------------

# --- 1. Backend reachability -------------------------------------------

title "1. Redis container reachable (PING)"
PING=$(redis_cli PING | tr -d '\r')
echo "PING : $PING"
if [ "$PING" = "PONG" ]; then
    pass "Redis reachable via docker compose exec"
else
    fail "expected PONG, got '$PING'"
fi

# --- 2. /showcase/cache/info confirms both Deps slots wired ------------

title "2. GET /showcase/cache/info reports both Deps slots configured"
INFO=$(curl -sf "$BASE/showcase/cache/info")
echo "RESPONSE: $INFO"
if echo "$INFO" | python3 -c "import json,sys; d=json.loads(sys.stdin.read())['data']; assert d['private']['configured']==True; assert d['shared']['configured']==True; print('ok')" >/dev/null 2>&1; then
    pass "Deps.Cache and Deps.SharedCache both non-nil"
else
    fail "info response missing or one of the slots is nil"
fi

# --- 3. Private cache CRUD ---------------------------------------------

title "3a. POST /showcase/cache/private/foo {value:bar, ttl:60} → 200"
STATUS=$(curl -sf -o /tmp/qa-cache.body -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" \
    -d '{"value":"bar","ttl_seconds":60}' \
    "$BASE/showcase/cache/private/foo")
echo "STATUS  : $STATUS"
if [ "$STATUS" = "200" ]; then
    pass "private Set succeeded"
else
    fail "expected 200, got $STATUS"
    head -c 200 /tmp/qa-cache.body
fi

title "3b. GET /showcase/cache/private/foo → 200 with value=bar"
STATUS=$(curl -sf -o /tmp/qa-cache.body -w "%{http_code}" "$BASE/showcase/cache/private/foo")
VALUE=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read())['data']['value'])" < /tmp/qa-cache.body 2>/dev/null)
echo "STATUS  : $STATUS"
echo "VALUE   : $VALUE"
if [ "$STATUS" = "200" ] && [ "$VALUE" = "bar" ]; then
    pass "private Get returned the stored value"
else
    fail "expected 200 + value=bar, got status=$STATUS value=$VALUE"
fi

title "3c. Redis carries the key under the PRIVATE prefix"
PRIVATE_KEYS=$(redis_cli KEYS "${PRIVATE_PREFIX}:*" | tr -d '\r' | grep -v '^$' || true)
echo "Matched: $(printf '%s\n' "$PRIVATE_KEYS" | wc -l | tr -d '[:space:]') key(s)"
if printf '%s\n' "$PRIVATE_KEYS" | grep -q "foo"; then
    pass "key 'foo' visible under prefix '$PRIVATE_PREFIX'"
else
    fail "key 'foo' not found under '$PRIVATE_PREFIX:*'"
    printf '%s\n' "$PRIVATE_KEYS" | head -n 3
fi

title "3d. DELETE /showcase/cache/private/foo → 200"
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" -X DELETE "$BASE/showcase/cache/private/foo")
echo "STATUS  : $STATUS"
if [ "$STATUS" = "200" ]; then
    pass "private Delete succeeded"
else
    fail "expected 200, got $STATUS"
fi

title "3e. GET /showcase/cache/private/foo after Delete → 404"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/showcase/cache/private/foo")
echo "STATUS  : $STATUS"
if [ "$STATUS" = "404" ]; then
    pass "deleted entry produces miss → 404"
else
    fail "expected 404, got $STATUS"
fi

# --- 4. Shared cache CRUD ----------------------------------------------

title "4a. POST /showcase/cache/shared/global → 200"
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" \
    -d '{"value":"team-wide","ttl_seconds":60}' \
    "$BASE/showcase/cache/shared/global")
echo "STATUS  : $STATUS"
if [ "$STATUS" = "200" ]; then
    pass "shared Set succeeded"
else
    fail "expected 200, got $STATUS"
fi

title "4b. GET /showcase/cache/shared/global → 200 with value=team-wide"
STATUS=$(curl -sf -o /tmp/qa-cache.body -w "%{http_code}" "$BASE/showcase/cache/shared/global")
VALUE=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read())['data']['value'])" < /tmp/qa-cache.body 2>/dev/null)
echo "STATUS  : $STATUS"
echo "VALUE   : $VALUE"
if [ "$STATUS" = "200" ] && [ "$VALUE" = "team-wide" ]; then
    pass "shared Get returned the stored value"
else
    fail "expected 200 + value=team-wide, got status=$STATUS value=$VALUE"
fi

title "4c. Redis carries the shared key under the SHARED prefix (distinct from private)"
SHARED_KEYS=$(redis_cli KEYS "${SHARED_PREFIX}:*" | tr -d '\r' | grep -v '^$' || true)
echo "Matched: $(printf '%s\n' "$SHARED_KEYS" | wc -l | tr -d '[:space:]') key(s)"
if printf '%s\n' "$SHARED_KEYS" | grep -q "global"; then
    pass "key 'global' visible under prefix '$SHARED_PREFIX'"
else
    fail "key 'global' not found under '$SHARED_PREFIX:*'"
fi

title "4d. PRIVATE and SHARED prefixes do not collide"
# A read against the private prefix MUST NOT see the shared key, and
# vice-versa.
PRIVATE_SAW_SHARED=$(redis_cli KEYS "${PRIVATE_PREFIX}:global" | tr -d '\r' | grep -v '^$' || true)
SHARED_SAW_PRIVATE=$(redis_cli KEYS "${SHARED_PREFIX}:foo" | tr -d '\r' | grep -v '^$' || true)
if [ -z "$PRIVATE_SAW_SHARED" ] && [ -z "$SHARED_SAW_PRIVATE" ]; then
    pass "no cross-prefix bleed — private and shared scopes are observably separated"
else
    fail "prefix collision: private saw [$PRIVATE_SAW_SHARED], shared saw [$SHARED_SAW_PRIVATE]"
fi

title "4e. DELETE /showcase/cache/shared/global → 200"
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" -X DELETE "$BASE/showcase/cache/shared/global")
if [ "$STATUS" = "200" ]; then
    pass "shared Delete succeeded"
else
    fail "expected 200, got $STATUS"
fi

# --- 5. TTL expiration -------------------------------------------------

title "5. POST with ttl=1 then GET after 2s → 404 (entry expired)"
curl -sf -o /dev/null -X POST -H "Content-Type: application/json" \
    -d '{"value":"ephemeral","ttl_seconds":1}' \
    "$BASE/showcase/cache/private/ephemeral"
sleep 2
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/showcase/cache/private/ephemeral")
echo "STATUS  : $STATUS"
if [ "$STATUS" = "404" ]; then
    pass "TTL honored — entry expired and produces miss"
else
    fail "expected 404 (expired), got $STATUS"
fi

# --- 6. Idempotent Delete of missing key -------------------------------

title "6. DELETE of non-existent key → 200 (idempotent)"
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" -X DELETE "$BASE/showcase/cache/private/nonexistent")
if [ "$STATUS" = "200" ]; then
    pass "Delete is idempotent — missing key is not an error"
else
    fail "expected 200, got $STATUS"
fi

# --- 7. httpclient response cache delegates to Deps.Cache --------------

title "7. httpclient response cache lands under the SAME private prefix"
# Hit /showcase/keycloak/realm — the httpclient response cache layer
# stores the response under the framework's key formula. The key path
# starts with `omnicore-example-users-cache:keycloak-public|...`,
# proving httpclient delegates to Deps.Cache (the same private backend
# the showcase routes use).
curl -sf -o /dev/null "$BASE/showcase/keycloak/realm"
HTTPCLIENT_KEYS=$(redis_cli KEYS "${PRIVATE_PREFIX}:*" | tr -d '\r' | grep keycloak-public || true)
echo "Matched: $(printf '%s\n' "$HTTPCLIENT_KEYS" | wc -l | tr -d '[:space:]') httpclient key(s)"
if [ -n "$HTTPCLIENT_KEYS" ]; then
    pass "httpclient cache consumes Deps.Cache (entry under private prefix, keycloak-public service segment)"
else
    fail "httpclient response cache did not land under the private prefix"
fi

# --- 8. Cross-process persistence — both private and shared --------------

title "8. Cross-process persistence (kill server, restart, entries survive)"
# Seed both private and shared, then kill the server and verify Redis
# still holds them when a fresh process reads back.
curl -sf -o /dev/null -X POST -H "Content-Type: application/json" \
    -d '{"value":"survive-private","ttl_seconds":60}' \
    "$BASE/showcase/cache/private/persist"
curl -sf -o /dev/null -X POST -H "Content-Type: application/json" \
    -d '{"value":"survive-shared","ttl_seconds":60}' \
    "$BASE/showcase/cache/shared/persist"
echo "Stopping server (PID=$SERVER_PID)..."
stop_server
echo "Server stopped; Redis still holding $(redis_cli DBSIZE | tr -d '\r') entries"
if ! start_server; then
    fail "cannot restart server"
else
    echo "Server restarted (new PID=$SERVER_PID)"
    PRIVATE_VAL=$(curl -sf "$BASE/showcase/cache/private/persist" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['data']['value'])" 2>/dev/null)
    SHARED_VAL=$(curl -sf "$BASE/showcase/cache/shared/persist" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['data']['value'])" 2>/dev/null)
    echo "Private value after restart : $PRIVATE_VAL"
    echo "Shared  value after restart : $SHARED_VAL"
    if [ "$PRIVATE_VAL" = "survive-private" ] && [ "$SHARED_VAL" = "survive-shared" ]; then
        pass "both private and shared entries survived the process restart"
    else
        fail "values lost across restart"
    fi
fi

# --- 9. failOpen — Redis down, requests still succeed --------------------

title "9. failOpen — stop Redis, requests still respond 200 + slog records the transport error"
echo "Stopping Redis container..."
$COMPOSE stop redis >/dev/null 2>&1
REDIS_STOPPED=1
LOG_LINES_BEFORE=$(wc -l < "$SERVER_LOG" | tr -d '[:space:]')

# 9a: Set against the down backend still returns 200 (failOpen swallows).
SET_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" \
    -d '{"value":"during-outage","ttl_seconds":60}' \
    "$BASE/showcase/cache/private/outage")

# 9b: Get against the down backend returns 404 (failOpen reports miss).
GET_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/showcase/cache/private/outage")

sleep 0.3
LOG_TAIL=$(tail -n +"$((LOG_LINES_BEFORE + 1))" "$SERVER_LOG")
echo "Set status  : $SET_STATUS"
echo "Get status  : $GET_STATUS"
SAW_TRANSPORT_ERROR=$(echo "$LOG_TAIL" | grep -c '"msg":"cache.redis.transport.error"' || true)
echo "slog transport.error lines : $SAW_TRANSPORT_ERROR"

if [ "$SET_STATUS" = "200" ] && [ "$GET_STATUS" = "404" ] && [ "$SAW_TRANSPORT_ERROR" -gt 0 ]; then
    pass "failOpen works — Set degrades to no-op (200), Get to miss (404), slog records the failure"
else
    fail "failOpen did not behave as documented (set=$SET_STATUS get=$GET_STATUS transport-errors=$SAW_TRANSPORT_ERROR)"
fi

echo "Restarting Redis..."
$COMPOSE start redis >/dev/null 2>&1
# Wait for Redis to become healthy again before the cleanup trap fires.
for _ in 1 2 3 4 5; do
    if redis_cli PING 2>/dev/null | grep -q PONG; then
        REDIS_STOPPED=0
        break
    fi
    sleep 1
done

# ------------------------------------------------------------------
sec "Summary"
echo "PASS=$PASS  FAIL=$FAIL"
echo
echo "Server log : $SERVER_LOG"
echo "Binary     : $SERVER_BIN"

[ "$FAIL" -eq 0 ]
