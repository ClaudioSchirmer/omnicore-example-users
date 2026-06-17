#!/usr/bin/env bash
# qa/httpclient-redis.sh — end-to-end validation of the framework's Redis
# cache backend (`defaults.cache.store: redis`) under
# OMNICORE_CONFIG_PATH=microservice.dev-redis-cache.yaml (kept under
# APP_PROFILE=dev so the framework's auth.mode=disabled guard keeps holding).
#
# Sibling of qa/httpclient.sh: that one runs under the dev profile (in-process
# memory cache) and proves the outbound-HTTP showcase end to end; this one
# swaps the cache backend to Redis and asserts the things only the Redis
# adapter can demonstrate — entries written to Redis with the configured key
# prefix, TTL honored, the wire shape decodes back as the framework declares,
# CROSS-PROCESS persistence (the actual reason Redis exists), and the
# failOpen graceful-degradation policy when Redis is unreachable.
#
# Prerequisites:
#   docker compose -f devops/docker-compose.yml up -d
#   ./devops/debezium/register-connector.sh
#
# The script manages the example service's lifecycle itself (build, kill_port-
# guarded boot, cleanup trap) so the operator does NOT keep a server running
# in another terminal — this isolates the Redis profile and lets case 5 stop
# and restart the server without fighting an already-running instance.
#
# Each case prints REQUEST/STATUS/PASS|FAIL. Exits non-zero on any failure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="docker compose -f $REPO_ROOT/devops/docker-compose.yml"
BASE="${BASE:-http://localhost:8080}"
SERVER_BIN="${SERVER_BIN:-/tmp/omnicore-example-users-qa-redis-bin}"
REDIS_KEY_PREFIX="${REDIS_KEY_PREFIX:-omnicore-example-users-httpcache}"
REDIS_STOPPED=0
SERVER_PID=""
SERVER_LOG="/tmp/omnicore-example-users-qa-httpclient-redis.log"

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
# Same primitive as qa/auth.sh — sends SIGTERM, then SIGKILL, to whoever holds
# the port. Used as a guard before every server start so a leaked process from
# a previous run does not silently keep the suite green by serving stale data.
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

# cleanup is run via EXIT/INT/TERM trap so any case that exits early still
# restores the side effects we made — the running server, and the redis
# container if case 6 stopped it.
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

# wait_for_health <timeout_seconds>
# Polls GET /health until 200 or the timeout expires.
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

# start_server starts the pre-built binary against
# microservice.dev-redis-cache.yaml — loaded via OMNICORE_CONFIG_PATH under
# APP_PROFILE=dev so the framework's profile-guard for auth.mode=disabled
# (which would otherwise reject every non-"dev" profile) keeps holding. The
# YAML name is informative — operators can grep for `dev-redis-cache.yaml` to
# discover the Redis-backed variant — without spending the JWT/Keycloak
# bring-up budget the prd-style profiles do.
#
# Output is redirected to $SERVER_LOG (appended so case 5's second boot
# joins the first boot's log).
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

# redis_cli runs commands inside the redis container via docker compose exec.
# Doing it through the container removes the host's redis-cli as a prerequisite
# — every machine that has docker also has the Redis CLI by this path.
redis_cli() {
    $COMPOSE exec -T redis redis-cli "$@"
}

# ------------------------------------------------------------------
sec "qa/httpclient-redis.sh"
# ------------------------------------------------------------------

title "0. Preconditions"

if ! $COMPOSE ps --status running --format '{{.Name}}' | grep -q omnicore-example-redis; then
    echo "Redis container not running. Bring it up first:"
    echo "  $COMPOSE up -d redis"
    exit 1
fi
if ! $COMPOSE ps --status running --format '{{.Name}}' | grep -q omnicore-example-keycloak; then
    echo "Keycloak container not running. Bring it up first:"
    echo "  $COMPOSE up -d keycloak"
    exit 1
fi

title "0.1 Build server binary"
(cd "$REPO_ROOT" && go build -o "$SERVER_BIN" ./bootstrap)
echo "Binary: $SERVER_BIN"

title "0.2 Clear Redis state (flushdb scoped to db 0)"
redis_cli FLUSHDB >/dev/null
echo "Redis flushed"

title "0.3 Free port 8080 + reset server log"
kill_port 8080
: > "$SERVER_LOG"
echo "Port 8080 clear; log $SERVER_LOG truncated"

title "0.4 Start server (APP_PROFILE=dev, OMNICORE_CONFIG_PATH=microservice.dev-redis-cache.yaml)"
if ! start_server; then
    echo "Cannot start server — aborting"
    exit 1
fi
echo "Server ready (PID=$SERVER_PID, config=microservice.dev-redis-cache.yaml)"

# ------------------------------------------------------------------
sec "Cases"
# ------------------------------------------------------------------

# --- Case 1: redis-cli reaches the container ------------------------------

title "1. redis-cli PING returns PONG"
PING=$(redis_cli PING | tr -d '\r')
echo "PING : $PING"
if [ "$PING" = "PONG" ]; then
    pass "Redis container reachable via docker exec"
else
    fail "expected PONG, got '$PING'"
fi

# --- Case 2: After /realm, Redis carries an entry under the keyPrefix ----

title "2. After GET /showcase/keycloak/realm, Redis has a prefixed key"
curl -sf "$BASE/showcase/keycloak/realm" >/dev/null
KEYS_BEFORE=$(redis_cli KEYS "${REDIS_KEY_PREFIX}:*" | tr -d '\r' | grep -v '^$' || true)
KEY_COUNT=$(printf '%s\n' "$KEYS_BEFORE" | grep -c . || true)
echo "Matching keys: $KEY_COUNT"
echo "Sample:        $(printf '%s\n' "$KEYS_BEFORE" | head -n 1)"
if [ "$KEY_COUNT" -ge 1 ] && printf '%s\n' "$KEYS_BEFORE" | head -n 1 | grep -q "keycloak-public"; then
    pass "Framework wrote at least 1 entry under the prefix, scoped to the keycloak-public service"
else
    fail "no entries under $REDIS_KEY_PREFIX:* OR sample key missing keycloak-public segment"
fi

# Capture one key for case 3 + 4.
CACHE_KEY=$(printf '%s\n' "$KEYS_BEFORE" | head -n 1)

# --- Case 3: The stored entry decodes back as valid JSON with the wire shape ---

title "3. Stored entry is valid JSON with the framework's CacheEntry fields"
RAW=$(redis_cli GET "$CACHE_KEY")
if ! echo "$RAW" | python3 -c "import json, sys; d = json.loads(sys.stdin.read()); assert 'body' in d and 'headers' in d and 'status' in d and 'expiresAt' in d, 'missing fields'; print('decoded fields:', sorted(d.keys()))"; then
    fail "stored entry does not decode as JSON with the CacheEntry shape (body/headers/status/expiresAt)"
else
    pass "entry is valid JSON carrying the framework's wire shape"
fi

# --- Case 4: TTL is positive and within the configured ceiling -----------

title "4. TTL is bounded by the endpoint's 5m configuration"
TTL=$(redis_cli TTL "$CACHE_KEY" | tr -d '\r')
echo "TTL : ${TTL}s"
# Endpoint declares ttl: 5m → 300s. Allow [1, 300] inclusive (Redis returns
# the remaining lifetime, so it can be anywhere up to the original TTL).
if [ "$TTL" -ge 1 ] && [ "$TTL" -le 300 ]; then
    pass "TTL within (1, 300] seconds — honors the YAML 5m"
else
    fail "TTL=$TTL outside the expected (1, 300]s window"
fi

# --- Case 5: Cross-process cache persistence (the Redis differentiator) --

title "5. Cross-process persistence — kill server, restart, cache survives"
echo "Stopping server (PID=$SERVER_PID)..."
stop_server
echo "Server stopped; Redis still holding $(redis_cli DBSIZE | tr -d '\r') entries"
if ! start_server; then
    fail "cannot restart server"
else
    echo "Server restarted (new PID=$SERVER_PID)"
    # Hit /realm in the FRESH process and check whether the framework emits
    # cacheStatus="hit" in slog. The previous process wrote the entry; if
    # cache is truly cross-process, the fresh process reads it without
    # touching Keycloak.
    LOG_LINES_BEFORE=$(wc -l < "$SERVER_LOG" | tr -d '[:space:]')
    curl -sf "$BASE/showcase/keycloak/realm" >/dev/null
    sleep 0.3
    # slice the log tail emitted after we called /realm
    LOG_TAIL=$(tail -n +"$((LOG_LINES_BEFORE + 1))" "$SERVER_LOG")
    # slog ships with the JSONHandler by default — emits the field as
    # `"cacheStatus":"hit"`, not the text-handler `cacheStatus=hit`.
    if echo "$LOG_TAIL" | grep -q '"cacheStatus":"hit"'; then
        pass "fresh server process observed cacheStatus=hit — entry persisted in Redis across the restart"
    else
        echo "DEBUG: log tail after /realm call (first 5 lines):"
        echo "$LOG_TAIL" | head -n 5
        fail "fresh process did NOT log cacheStatus=hit — cache did not survive the restart"
    fi
fi

# --- Case 6: failOpen — Redis unreachable, calls still succeed -----------

title "6. failOpen — stop Redis, /realm still 200, slog records the transport error"
echo "Stopping Redis container..."
$COMPOSE stop redis >/dev/null 2>&1
REDIS_STOPPED=1
# Mark the log offset BEFORE the next request so we only inspect new lines.
LOG_LINES_BEFORE=$(wc -l < "$SERVER_LOG" | tr -d '[:space:]')
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE/showcase/keycloak/realm")
echo "STATUS  : $STATUS"
sleep 0.3
LOG_TAIL=$(tail -n +"$((LOG_LINES_BEFORE + 1))" "$SERVER_LOG")
if [ "$STATUS" = "200" ] && echo "$LOG_TAIL" | grep -q 'httpclient.cache.redis.transport.error'; then
    pass "service still responds 200 + slog.Warn captures the transport.error — failOpen works"
else
    if [ "$STATUS" != "200" ]; then
        echo "DEBUG: status=$STATUS (expected 200 — failOpen should degrade gracefully)"
    fi
    if ! echo "$LOG_TAIL" | grep -q 'httpclient.cache.redis.transport.error'; then
        echo "DEBUG: no transport.error in log tail — was Redis actually down at request time?"
        echo "$LOG_TAIL" | head -n 8
    fi
    fail "failOpen did not behave as documented"
fi
echo "Restarting Redis..."
$COMPOSE start redis >/dev/null 2>&1
# Wait for redis to be ready again before the cleanup trap runs.
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
# cleanup trap fires here, stopping the server and ensuring Redis is up.

[ "$FAIL" -eq 0 ]
