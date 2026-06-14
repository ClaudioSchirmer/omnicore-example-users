#!/usr/bin/env bash
# Auth E2E suite for omnicore-example-users.
#
# Exercises the four JWT validator modes the framework supports — local JWKS,
# local PEM, external (no cache), external (cache opt-in) — against a real
# Keycloak realm. Each mode is run in a separate APP_PROFILE swap so the same
# fixtures hit every code path of the auth middleware.
#
# Companion to qa/e2e.sh: e2e.sh validates write/read endpoints with
# auth.mode=disabled (microservice.dev.yaml); this script validates the auth
# middleware itself with auth.mode=jwt and the IdP wired in.
#
# Prerequisites (same as e2e.sh, plus Keycloak):
#   docker compose -f devops/docker-compose.yml up -d
#   ./devops/debezium/register-connector.sh
# Then this script orchestrates the rest (start/stop the Go server with each
# profile, mint tokens, hit endpoints, assert).
#
# Run from anywhere:  bash qa/auth.sh

set -u

BASE="${BASE:-http://localhost:8080}"
KC_URL="${KC_URL:-http://localhost:8088}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${REPO_ROOT}/devops/keycloak"
SERVER_BIN="/tmp/omnicore-example-users-qa-auth"

PASS=0; FAIL=0
SERVER_PID=""
SERVER_LOG=""

hr() { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec() { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }

# kill_port <port>
# Frees the TCP port by sending SIGTERM, then SIGKILL, to whoever is listening.
# Used as a guard before starting a new server — a leaked process from a previous
# run would shadow every "fresh" profile boot and silently keep the suite green.
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

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  kill_port 8080
}
trap cleanup EXIT INT TERM

# wait_for_health <timeout_seconds>
# Polls GET /health until 200 or the timeout expires. Used after starting the
# server with a new APP_PROFILE — bootstrap.Run does migrations + Kafka connect
# before serving, so the readiness window varies.
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

# start_server <profile>
# Starts the pre-built server binary in the background with APP_PROFILE=<profile>,
# redirecting stdout/stderr to /tmp/auth-server-<profile>.log. Waits for /health.
# Direct binary execution (not `go run`) so $! is the actual server PID — `go run`
# spawns a child binary that survives `kill $!` and would leak across profiles.
start_server() {
  local profile="$1"
  SERVER_LOG="/tmp/auth-server-${profile}.log"
  : > "$SERVER_LOG"
  kill_port 8080
  (
    cd "$REPO_ROOT"
    APP_PROFILE="$profile" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1
  ) &
  SERVER_PID=$!
  if ! wait_for_health 30; then
    echo "ERROR: server (APP_PROFILE=$profile) did not become ready in 30s" >&2
    echo "--- last 40 lines of $SERVER_LOG ---" >&2
    tail -n 40 "$SERVER_LOG" >&2
    return 1
  fi
  echo "Server ready (PID=$SERVER_PID, profile=$profile, log=$SERVER_LOG)"
}

stop_server() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
  kill_port 8080
}

# show_case <name> <method> <path> <bearer_token_or_empty> <expected_status> [expected_subject_or_empty]
# Hits $BASE$path with optional Authorization header, asserts the HTTP status,
# and optionally asserts that the response JSON's $.data.subject equals an
# expected value. Subject check is skipped when the field is absent (non-whoami
# endpoints).
show_case() {
  local name="$1" method="$2" path="$3" token="$4" expected="$5" expected_subject="${6:-}"
  title "$name"
  echo "REQUEST : $method $path"
  if [ -n "$token" ]; then
    echo "AUTH    : Bearer <token-${#token}-chars>"
  else
    echo "AUTH    : (none)"
  fi
  local tmp; tmp=$(mktemp)
  local status
  if [ -n "$token" ]; then
    status=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" \
      -H "Authorization: Bearer $token" -H "Accept-Language: en-US")
  else
    status=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" \
      -H "Accept-Language: en-US")
  fi
  echo "STATUS  : $status"
  echo "RESPONSE:"
  if [ -s "$tmp" ]; then
    python3 -m json.tool < "$tmp" 2>/dev/null || cat "$tmp"
    echo
  else
    echo "(empty body)"
  fi

  local ok=1
  if [ "$status" != "$expected" ]; then
    ok=0
    printf '\033[1;31mFAIL\033[0m (expected status %s, got %s)\n' "$expected" "$status"
  fi
  if [ -n "$expected_subject" ] && [ "$ok" = "1" ]; then
    local got
    got=$(python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); sys.exit(0)
data = d.get("data") or {}
print(data.get("subject", ""))
' "$tmp")
    if [ "$got" != "$expected_subject" ]; then
      ok=0
      printf '\033[1;31mFAIL\033[0m (expected subject %s, got %s)\n' "$expected_subject" "$got"
    fi
  fi
  if [ "$ok" = "1" ]; then
    printf '\033[1;32mPASS\033[0m\n'
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
  fi
  rm -f "$tmp"
}

# show_case_with_key — same as show_case, plus assertion on the first error's
# notificationKey. Used by the expansion block to pin the typed identity of
# 401 / 403 envelopes (MissingAuthorizationNotification vs
# InvalidTokenNotification etc.) so a regression that swaps the notification
# type doesn't silently pass under the same status code.
show_case_with_key() {
  local name="$1" method="$2" path="$3" extra_header="$4" expected="$5" expected_key="${6:-}"
  title "$name"
  echo "REQUEST : $method $path"
  if [ -n "$extra_header" ]; then
    echo "HEADER  : $extra_header"
  fi
  local tmp; tmp=$(mktemp)
  local status
  if [ -n "$extra_header" ]; then
    status=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" \
      -H "$extra_header" -H "Accept-Language: en-US")
  else
    status=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" \
      -H "Accept-Language: en-US")
  fi
  echo "STATUS  : $status"
  echo "RESPONSE:"
  if [ -s "$tmp" ]; then
    python3 -m json.tool < "$tmp" 2>/dev/null || cat "$tmp"
    echo
  fi
  local ok=1
  if [ "$status" != "$expected" ]; then
    ok=0
    printf '\033[1;31mFAIL\033[0m (expected status %s, got %s)\n' "$expected" "$status"
  fi
  if [ -n "$expected_key" ] && [ "$ok" = "1" ]; then
    local got_key
    got_key=$(python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); sys.exit(0)
errs = d.get("errors") or []
if not errs:
    print(""); sys.exit(0)
msgs = errs[0].get("messages") or []
if not msgs:
    print(""); sys.exit(0)
print(msgs[0].get("notificationKey", ""))
' "$tmp")
    if [ "$got_key" != "$expected_key" ]; then
      ok=0
      printf '\033[1;31mFAIL\033[0m (expected notificationKey %s, got %s)\n' "$expected_key" "$got_key"
    fi
  fi
  if [ "$ok" = "1" ]; then
    printf '\033[1;32mPASS\033[0m\n'
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
  fi
  rm -f "$tmp"
}

# Sanity: Keycloak reachable + token mint works + server binary built before
# any profile run.
sec "0. Preconditions"
title "0.1 Keycloak realm ready"
if ! "$SCRIPTS/wait-ready.sh" 30 >/dev/null 2>&1; then
  echo "Keycloak not reachable at $KC_URL — bring it up with 'docker compose -f devops/docker-compose.yml up -d keycloak' first." >&2
  exit 1
fi
echo "OK — realm reachable"

title "0.1b Build server binary (once, reused across all profiles)"
(cd "$REPO_ROOT" && go build -o "$SERVER_BIN" ./bootstrap)
echo "Binary: $SERVER_BIN"

title "0.1c Free port 8080 if anything is lingering from a previous run"
kill_port 8080
echo "Port 8080 clear"

title "0.2 Resolve alice subject UUID (decoded from her own JWT — avoids admin API)"
PRIMER=$("$SCRIPTS/mint-token.sh" alice)
if [ -z "$PRIMER" ]; then
  echo "ERROR: could not mint primer token for alice" >&2
  exit 1
fi
ALICE_SUB=$(python3 -c '
import json, base64, sys
def pad(s): return s + "=" * (-len(s) % 4)
payload = json.loads(base64.urlsafe_b64decode(pad(sys.argv[1].split(".")[1])))
print(payload.get("sub", ""))
' "$PRIMER")
echo "alice sub = $ALICE_SUB"
if [ -z "$ALICE_SUB" ]; then
  echo "ERROR: could not extract sub claim from alice's JWT" >&2
  exit 1
fi

title "0.3 Resolve bob subject UUID (separate user — verifies subject propagation isn't hardcoded)"
BOB_PRIMER=$("$SCRIPTS/mint-token.sh" bob)
if [ -z "$BOB_PRIMER" ]; then
  echo "ERROR: could not mint primer token for bob" >&2
  exit 1
fi
BOB_SUB=$(python3 -c '
import json, base64, sys
def pad(s): return s + "=" * (-len(s) % 4)
payload = json.loads(base64.urlsafe_b64decode(pad(sys.argv[1].split(".")[1])))
print(payload.get("sub", ""))
' "$BOB_PRIMER")
echo "bob sub = $BOB_SUB"
if [ -z "$BOB_SUB" ]; then
  echo "ERROR: could not extract sub claim from bob's JWT" >&2
  exit 1
fi
if [ "$ALICE_SUB" = "$BOB_SUB" ]; then
  echo "ERROR: alice and bob have the same sub — realm export broken" >&2
  exit 1
fi

# Profile loop. The canonical prd profile (local JWKS) runs first because it
# exercises the most common production setup.
PROFILES=(prd prd-pem prd-external prd-external-cached)

for PROFILE in "${PROFILES[@]}"; do
  sec "Profile: $PROFILE"

  start_server "$PROFILE" || { FAIL=$((FAIL+1)); continue; }

  # Fresh tokens per profile so cache state from prior runs cannot leak across
  # the external-cached scenarios.
  VALID=$("$SCRIPTS/mint-token.sh" alice)
  WRONG_AUD=$("$SCRIPTS/mint-token.sh" wrong-aud)
  MALFORMED="not.a.valid.jwt"

  show_case "Public route accepts anonymous (publicRoutes bypass)" \
    GET /health "" 200
  show_case "Protected route rejects missing bearer (MissingAuthorizationNotification)" \
    GET /whoami "" 401
  show_case "Protected route rejects malformed JWT (InvalidTokenNotification)" \
    GET /whoami "$MALFORMED" 401
  show_case "Protected route rejects wrong-audience JWT (audience pin)" \
    GET /whoami "$WRONG_AUD" 401
  show_case "Protected route accepts valid alice JWT" \
    GET /whoami "$VALID" 200 "$ALICE_SUB"

  # ─── Expansion block — typed notification keys + bob + bearer variants ───

  VALID_BOB=$("$SCRIPTS/mint-token.sh" bob)

  # Subject propagation works for a second distinct user — proves the JWT
  # parser doesn't hardcode alice anywhere.
  show_case "Bob's JWT carries Bob's subject (subject propagation works for multiple users)" \
    GET /whoami "$VALID_BOB" 200 "$BOB_SUB"

  # Notification key pin: the missing-bearer case must carry the specific
  # typed notification, not any 401. Catches a regression where the
  # middleware emits a different envelope under the same status.
  show_case_with_key "401 envelope key = MissingAuthorizationNotification (no Authorization header)" \
    GET /whoami "" 401 MissingAuthorizationNotification

  show_case_with_key "401 envelope key = InvalidTokenNotification (malformed JWT)" \
    GET /whoami "Authorization: Bearer $MALFORMED" 401 InvalidTokenNotification

  show_case_with_key "401 envelope key = InvalidTokenNotification (wrong audience)" \
    GET /whoami "Authorization: Bearer $WRONG_AUD" 401 InvalidTokenNotification

  # Bearer scheme edge cases: the AuthMiddleware checks the scheme case-
  # insensitively, but the token must be present after it.

  show_case_with_key "Empty Authorization header → 401 MissingAuthorizationNotification" \
    GET /whoami "Authorization: " 401 MissingAuthorizationNotification

  show_case_with_key "'Bearer' with no token → 401 MissingAuthorizationNotification" \
    GET /whoami "Authorization: Bearer" 401 MissingAuthorizationNotification

  show_case_with_key "'Bearer ' (trailing space, no token) → 401 MissingAuthorizationNotification" \
    GET /whoami "Authorization: Bearer " 401 MissingAuthorizationNotification

  show_case_with_key "Wrong scheme (Basic xxx) → 401 MissingAuthorizationNotification" \
    GET /whoami "Authorization: Basic dXNlcjpwYXNz" 401 MissingAuthorizationNotification

  # publicRoutes bypass — verify the documentation surface stays anonymous.
  show_case "/openapi.json — public (added to publicRoutes automatically)" \
    GET /openapi.json "" 200

  show_case "/docs — public (added to publicRoutes automatically)" \
    GET /docs "" 200

  # Protected route on a different handler (canonical /users) verifies the
  # middleware is registered globally, not only on /whoami.
  show_case_with_key "GET /users without bearer → 401 (middleware applies to all non-public routes)" \
    GET /users "" 401 MissingAuthorizationNotification

  # Public route still rejects bearer-less when there's a bearer header but
  # it's wrong — the publicRoutes bypass is by route match, not by header
  # presence. /health stays open even with a malformed token.
  show_case "GET /health with malformed bearer → 200 (public bypass ignores headers)" \
    GET /health "$MALFORMED" 200

  case "$PROFILE" in
    prd-external)
      # Mint a new token so the revoked one isn't shared with other scenarios.
      REVOKEE=$("$SCRIPTS/mint-token.sh" alice)
      show_case "Pre-revoke: external validator allows active token" \
        GET /whoami "$REVOKEE" 200 "$ALICE_SUB"
      title "Revoke token via RFC 7009 /revoke"
      "$SCRIPTS/revoke-session.sh" "$REVOKEE"
      show_case "Post-revoke: external validator rejects (cacheTtlSeconds=0, every request hits IdP)" \
        GET /whoami "$REVOKEE" 401
      ;;
    prd-external-cached)
      REVOKEE=$("$SCRIPTS/mint-token.sh" alice)
      show_case "Pre-revoke: external+cache allows active token (populates cache)" \
        GET /whoami "$REVOKEE" 200 "$ALICE_SUB"
      title "Revoke token via RFC 7009 /revoke"
      "$SCRIPTS/revoke-session.sh" "$REVOKEE"
      show_case "Post-revoke within TTL: cache still says active (positive cache hit, by design)" \
        GET /whoami "$REVOKEE" 200 "$ALICE_SUB"
      title "Sleep 31s — wait for cacheTtlSeconds=30 to elapse"
      sleep 31
      show_case "Post-revoke after TTL: cache expired, IdP says inactive → 401" \
        GET /whoami "$REVOKEE" 401
      ;;
  esac

  stop_server
done

sec "Summary"
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
