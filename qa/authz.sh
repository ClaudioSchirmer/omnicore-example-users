#!/usr/bin/env bash
# Authorization E2E suite for omnicore-example-users.
#
# Exercises the declarative permission layer the framework adds on top of the
# JWT auth middleware. Companion to qa/auth.sh (which validates authentication
# in isolation): this script validates that
#
#   1. The runtime gate (Layer 1) rejects requests whose JWT lacks the
#      permission declared via fwopenapi.RequirePermission on each route.
#   2. The domain owner-check (Layer 2) rejects Archive when the principal's
#      email claim does not match the persisted user's email — unless the
#      principal carries users:admin (super-admin / *:* bypass).
#   3. Public routes (RawSpec.Public:true + auth.publicRoutes) bypass both
#      the AuthMiddleware AND the permission gate, so /health stays anonymous.
#
# Runs under APP_PROFILE=prd-authz, which carries auth.mode=jwt PLUS
# auth.authorization.enabled=true so the gate enforces (under any other
# profile the gate no-ops and the same RequirePermission options are inert).
#
# Test subjects (defined in devops/keycloak/realm-export.json):
#   alice   — permissions: [users:read, users:write, users:archive]
#             email claim: alice@omnicore.test  (Layer-2 owner of users with that email)
#   bob     — permissions: [*:*]  (super admin)
#             email claim: bob@omnicore.test
#   noperm  — no permissions claim emitted (negative tests)
#             email claim: noperm@omnicore.test
#
# Prerequisites (same as qa/auth.sh):
#   docker compose -f devops/docker-compose.yml up -d
#   ./devops/debezium/register-connector.sh
# Then this script orchestrates the rest (start/stop server, mint tokens,
# fire requests, assert).
#
# Run from anywhere:  bash qa/authz.sh

set -u

BASE="${BASE:-http://localhost:8080}"
KC_URL="${KC_URL:-http://localhost:8088}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${REPO_ROOT}/devops/keycloak"
SERVER_BIN="/tmp/omnicore-example-users-qa-authz"

PASS=0; FAIL=0
SERVER_PID=""
SERVER_LOG=""
CREATED_USER_ID=""

hr() { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec() { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }

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

start_server() {
  local profile="$1"
  SERVER_LOG="/tmp/authz-server-${profile}.log"
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

# show_case <name> <method> <path> <bearer_or_empty> <body_or_empty> <expected_status> [expected_key]
#
# Hits $BASE$path, asserts the HTTP status, and optionally asserts that the
# response envelope's first error notificationKey equals expected_key. The
# notification-key check anchors the rejection on the typed identity
# (MissingPermissionNotification vs ArchiveNotAllowedNotification etc.) so a
# 403 from the wrong cause does not silently pass.
show_case() {
  local name="$1" method="$2" path="$3" token="$4" body="$5" expected="$6" expected_key="${7:-}"
  title "$name"
  echo "REQUEST : $method $path"
  if [ -n "$token" ]; then
    echo "AUTH    : Bearer <token-${#token}-chars>"
  else
    echo "AUTH    : (none)"
  fi
  if [ -n "$body" ]; then
    echo "BODY    : $body"
  fi
  local tmp; tmp=$(mktemp)
  local status
  local curl_args=(-sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path"
    -H "Accept-Language: en-US")
  if [ -n "$token" ]; then
    curl_args+=(-H "Authorization: Bearer $token")
  fi
  if [ -n "$body" ]; then
    curl_args+=(-H "Content-Type: application/json" -d "$body")
  fi
  status=$(curl "${curl_args[@]}")
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

# show_gql_case <name> <bearer_or_empty> <graphql_query> <expected_key|ALLOW>
#
# POSTs a GraphQL operation to /graphql and asserts the Layer-1 gate outcome.
# GraphQL always answers HTTP 200; the gate result travels in errors[].extensions
# (NOT the REST messages[] shape show_case parses), so this twin reads
# errors[0].extensions.notificationKey. expected_key="ALLOW" asserts the gate
# passed (no errors[] → the field resolved); otherwise it asserts the first
# error's notificationKey equals expected_key (e.g. MissingPermissionNotification).
show_gql_case() {
  local name="$1" token="$2" query="$3" expected_key="$4"
  title "$name"
  local tmp; tmp=$(mktemp)
  local payload; payload=$(python3 -c 'import json,sys; print(json.dumps({"query": sys.argv[1]}))' "$query")
  local curl_args=(-sS -o "$tmp" -w "%{http_code}" -X POST "$BASE/graphql"
    -H "Accept-Language: en-US" -H "Content-Type: application/json" -d "$payload")
  [ -n "$token" ] && curl_args+=(-H "Authorization: Bearer $token")
  local status; status=$(curl "${curl_args[@]}")
  echo "STATUS  : $status"
  echo "RESPONSE:"
  python3 -m json.tool < "$tmp" 2>/dev/null || cat "$tmp"; echo
  local ok=1
  if [ "$status" != "200" ]; then
    ok=0; printf '\033[1;31mFAIL\033[0m (expected status 200, got %s)\n' "$status"
  fi
  local got
  got=$(python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("PARSE_ERR"); sys.exit(0)
errs = d.get("errors") or []
if not errs:
    print("ALLOW"); sys.exit(0)
print((errs[0].get("extensions") or {}).get("notificationKey", ""))
' "$tmp")
  if [ "$got" != "$expected_key" ]; then
    ok=0; printf '\033[1;31mFAIL\033[0m (expected %s, got %s)\n' "$expected_key" "$got"
  fi
  if [ "$ok" = "1" ]; then printf '\033[1;32mPASS\033[0m\n'; PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
  rm -f "$tmp"
}

# wait_for_user_in_view <bearer> <email> — polls GET /users?email= until the
# Debezium → Kafka → SyncEngine pipeline materializes the just-created user into
# the Mongo read view (the field-access assertions read from that view).
wait_for_user_in_view() {
  local token="$1" email="$2" i=0
  while [ "$i" -lt 60 ]; do
    if curl -sS -H "Authorization: Bearer $token" "$BASE/users?email=$email" 2>/dev/null | grep -q "$email"; then
      return 0
    fi
    sleep 1; i=$((i+1))
  done
  return 1
}

# assert_phone_visibility <name> <bearer> <present|absent> — GET /users and
# assert whether any returned row carries a "phone" field. Anchors the
# field-level read-access showcase (Phone is admin-only via ReadCriteria.Restrict).
assert_phone_visibility() {
  local name="$1" token="$2" expect="$3"
  title "$name"
  local tmp status has
  tmp=$(mktemp)
  status=$(curl -sS -o "$tmp" -w "%{http_code}" -H "Accept-Language: en-US" \
    -H "Authorization: Bearer $token" "$BASE/users?limit=100")
  has=$(python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("error"); sys.exit(0)
data = d.get("data") or []
print("present" if any(isinstance(u, dict) and "phone" in u for u in data) else "absent")
' "$tmp")
  echo "STATUS  : $status   phone in payload: $has"
  if [ "$status" = "200" ] && [ "$has" = "$expect" ]; then
    printf '\033[1;32mPASS\033[0m\n'; PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m (expected phone %s at 200, got %s at %s)\n' "$expect" "$has" "$status"
    FAIL=$((FAIL+1))
  fi
  rm -f "$tmp"
}

# extract_id_from <tmp_path> — pulls .data.id from a JSON envelope. Used after
# POST /users so the rest of the suite knows what to archive/delete.
extract_id_from() {
  python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); sys.exit(0)
data = d.get("data") or {}
print(data.get("id", ""))
' "$1"
}

# capture_post returns the created id from POST /users via $CAPTURE_ID. The
# request shape mirrors qa/e2e.sh's "minimal valid user" to keep the cross-
# suite invariant single-source.
capture_post() {
  local token="$1" email="$2"
  local body
  body=$(cat <<JSON
{
  "name": "Authz Test User",
  "email": "${email}",
  "phone": "14155551234"
}
JSON
  )
  local tmp; tmp=$(mktemp)
  local status
  status=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST "$BASE/users" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body")
  if [ "$status" != "201" ]; then
    echo "capture_post: unexpected status $status (body=$(cat "$tmp"))" >&2
    CAPTURE_ID=""
    rm -f "$tmp"
    return 1
  fi
  CAPTURE_ID=$(extract_id_from "$tmp")
  rm -f "$tmp"
  if [ -z "$CAPTURE_ID" ]; then
    echo "capture_post: could not extract id" >&2
    return 1
  fi
  return 0
}

# Preconditions
sec "0. Preconditions"

title "0.1 Keycloak realm ready"
if ! "$SCRIPTS/wait-ready.sh" 30 >/dev/null 2>&1; then
  echo "Keycloak not reachable at $KC_URL — bring it up with 'docker compose -f devops/docker-compose.yml up -d keycloak' first." >&2
  exit 1
fi
echo "OK — realm reachable"

title "0.2 Build server binary"
(cd "$REPO_ROOT" && go build -o "$SERVER_BIN" ./bootstrap)
echo "Binary: $SERVER_BIN"

title "0.3 Free port 8080 if lingering"
kill_port 8080
echo "Port 8080 clear"

title "0.4 Mint tokens (alice, bob, noperm)"
TOK_ALICE=$("$SCRIPTS/mint-token.sh" alice)
TOK_BOB=$("$SCRIPTS/mint-token.sh" bob)
TOK_NOPERM=$("$SCRIPTS/mint-token.sh" noperm)
if [ -z "$TOK_ALICE" ] || [ -z "$TOK_BOB" ] || [ -z "$TOK_NOPERM" ]; then
  echo "ERROR: could not mint one or more tokens" >&2
  exit 1
fi
echo "alice/bob/noperm tokens minted"

title "0.5 Verify permissions claim on the access token"
ALICE_PERMS=$(python3 -c '
import json, base64, sys
def pad(s): return s + "=" * (-len(s) % 4)
payload = json.loads(base64.urlsafe_b64decode(pad(sys.argv[1].split(".")[1])))
perms = payload.get("permissions")
print(json.dumps(perms))
' "$TOK_ALICE")
echo "alice permissions claim = $ALICE_PERMS"
if [ "$ALICE_PERMS" = "null" ] || [ -z "$ALICE_PERMS" ]; then
  echo "ERROR: alice's token does not carry the permissions claim. Did the realm import include the Protocol Mapper?" >&2
  exit 1
fi

# Server boot
sec "1. Boot — APP_PROFILE=prd-authz"
start_server prd-authz || exit 1

# Scenarios
sec "2. Public routes bypass both AuthMiddleware AND the gate"

show_case "GET /health — public via auth.publicRoutes" \
  GET /health "" "" 200

show_case "GET /openapi.json — public (added to publicRoutes automatically)" \
  GET /openapi.json "" "" 200

sec "3. Layer-1 — missing bearer rejected by AuthMiddleware (401), not by the gate"

show_case "POST /users without bearer → 401 MissingAuthorizationNotification" \
  POST /users "" "" 401 MissingAuthorizationNotification

show_case "GET /users without bearer → 401" \
  GET /users "" "" 401 MissingAuthorizationNotification

sec "4. Layer-1 — bearer present but no permission claim → 403 MissingPermissionNotification"

show_case "POST /users with noperm bearer → 403 (needs users:write)" \
  POST /users "$TOK_NOPERM" \
  '{"name":"x","email":"x@e.test","phone":"14155550000"}' \
  403 MissingPermissionNotification

show_case "GET /users with noperm bearer → 403 (needs users:read)" \
  GET /users "$TOK_NOPERM" "" 403 MissingPermissionNotification

sec "5. Layer-1 — partial permissions: alice has read/write/archive but NOT delete"

show_case "GET /users with alice bearer → 200 (alice has users:read)" \
  GET /users "$TOK_ALICE" "" 200

title "5.1 Create a user the rest of the suite will archive/delete (owned by alice)"
if ! capture_post "$TOK_ALICE" "alice@omnicore.test"; then
  echo "ERROR: could not create the target user" >&2
  FAIL=$((FAIL+1))
else
  CREATED_USER_ID="$CAPTURE_ID"
  echo "Created user id=$CREATED_USER_ID"
  PASS=$((PASS+1))
fi

if [ -n "$CREATED_USER_ID" ]; then
  show_case "DELETE /users/:id with alice → 403 (alice lacks users:delete)" \
    DELETE "/users/$CREATED_USER_ID" "$TOK_ALICE" "" \
    403 MissingPermissionNotification
fi

sec "6. Layer-2 — owner-check on Archive runs after Layer-1 passes"

# alice HAS users:archive (Layer-1 passes). Layer-2 then checks the JWT email
# claim against the persisted user's email. The target user was created with
# email alice@omnicore.test → alice IS the owner → archive succeeds. Then
# unarchive to keep state clean for the negative test.
if [ -n "$CREATED_USER_ID" ]; then
  show_case "PATCH /users/:id/archive with alice (owner) → 200" \
    PATCH "/users/$CREATED_USER_ID/archive" "$TOK_ALICE" "" 200

  show_case "PATCH /users/:id/unarchive with alice (owner) → 200" \
    PATCH "/users/$CREATED_USER_ID/unarchive" "$TOK_ALICE" "" 200

  # Now create a SECOND target whose email differs from alice's, then alice
  # tries to archive — Layer-1 passes (users:archive) but Layer-2 rejects
  # because alice is not the owner AND not an admin.
  title "6.1 Create a second user with a different email (not owned by alice)"
  if capture_post "$TOK_ALICE" "stranger@authz.test"; then
    STRANGER_ID="$CAPTURE_ID"
    echo "Created stranger id=$STRANGER_ID"
    PASS=$((PASS+1))

    show_case "PATCH /users/:id/archive with alice (NOT owner, not admin) → 403 ArchiveNotAllowedNotification" \
      PATCH "/users/$STRANGER_ID/archive" "$TOK_ALICE" "" \
      403 ArchiveNotAllowedNotification

    show_case "PATCH /users/:id/archive with bob (super admin *:*) → 200 (Layer-2 bypass)" \
      PATCH "/users/$STRANGER_ID/archive" "$TOK_BOB" "" 200

    # No DELETE on $STRANGER_ID after archive — the framework's FindByID filters
    # archived records, so DELETE would return 404 (RecordNotFound). Section 7
    # covers super-admin DELETE on an active (unarchived) user via the primary
    # target.
  else
    echo "ERROR: could not create stranger user" >&2
    FAIL=$((FAIL+1))
  fi
fi

sec "7. Layer-1 + Layer-2 — bob's super-admin pass-through on the primary target"

if [ -n "$CREATED_USER_ID" ]; then
  show_case "DELETE /users/:id with bob → 204 (bob has *:* including users:delete)" \
    DELETE "/users/$CREATED_USER_ID" "$TOK_BOB" "" 204
  CREATED_USER_ID=""
fi

sec "8. Manual showcase routes carry the same authz matrix"

show_case "GET /showcase/users-custom with noperm → 403 (manual showcase requires users:read)" \
  GET /showcase/users-custom "$TOK_NOPERM" "" 403 MissingPermissionNotification

show_case "GET /showcase/users-custom with alice → 200" \
  GET /showcase/users-custom "$TOK_ALICE" "" 200

sec "9. Layer-1 — every write verb requires the matching permission"

# Original block covers POST (write) and DELETE (delete). Cover PUT, PATCH
# and the dedicated archive/unarchive verbs to lock the full matrix.
# alice has users:write+archive but NOT users:delete; noperm has nothing.

show_case "PUT /users/:id with noperm → 403 (needs users:write)" \
  PUT /users/00000000-0000-0000-0000-000000000000 "$TOK_NOPERM" \
  '{"name":"x","email":"x@e.test","phone":"14155551234","addresses":[]}' \
  403 MissingPermissionNotification

show_case "PATCH /users/:id with noperm → 403 (needs users:write)" \
  PATCH /users/00000000-0000-0000-0000-000000000000 "$TOK_NOPERM" \
  '{"name":"x"}' 403 MissingPermissionNotification

show_case "PATCH /users/:id/archive with noperm → 403 (needs users:archive)" \
  PATCH /users/00000000-0000-0000-0000-000000000000/archive "$TOK_NOPERM" "" \
  403 MissingPermissionNotification

show_case "PATCH /users/:id/unarchive with noperm → 403 (needs users:archive)" \
  PATCH /users/00000000-0000-0000-0000-000000000000/unarchive "$TOK_NOPERM" "" \
  403 MissingPermissionNotification

show_case "GET /users/:id with noperm → 403 (needs users:read)" \
  GET /users/00000000-0000-0000-0000-000000000000 "$TOK_NOPERM" "" \
  403 MissingPermissionNotification

sec "10. Manual showcase — full write verb matrix mirrors canonical"

# The manual showcase is keyed by email; every endpoint declares
# RequirePermission(users:<verb>) too. Verify each verb rejects noperm
# AND that error notificationKey == MissingPermissionNotification (Layer-1)
# never reaches BuildRules.

show_case "POST /showcase/users-custom with noperm → 403 (needs users:write)" \
  POST /showcase/users-custom/ "$TOK_NOPERM" \
  '{"name":"x","email":"x@e.test","phone":"14155551234","addresses":[]}' \
  403 MissingPermissionNotification

show_case "PUT /showcase/users-custom/{email} with noperm → 403" \
  PUT /showcase/users-custom/x@example.com "$TOK_NOPERM" \
  '{"name":"x","phone":"14155551234","addresses":[]}' \
  403 MissingPermissionNotification

show_case "PATCH /showcase/users-custom/{email} with noperm → 403" \
  PATCH /showcase/users-custom/x@example.com "$TOK_NOPERM" \
  '{"name":"x"}' 403 MissingPermissionNotification

show_case "PATCH /showcase/users-custom/{email}/archive with noperm → 403" \
  PATCH /showcase/users-custom/x@example.com/archive "$TOK_NOPERM" "" \
  403 MissingPermissionNotification

show_case "PATCH /showcase/users-custom/{email}/unarchive with noperm → 403" \
  PATCH /showcase/users-custom/x@example.com/unarchive "$TOK_NOPERM" "" \
  403 MissingPermissionNotification

show_case "DELETE /showcase/users-custom/{email} with noperm → 403" \
  DELETE /showcase/users-custom/x@example.com "$TOK_NOPERM" "" \
  403 MissingPermissionNotification

show_case "GET /showcase/users-custom/{email} with noperm → 403" \
  GET /showcase/users-custom/x@example.com "$TOK_NOPERM" "" \
  403 MissingPermissionNotification

sec "11. /whoami — anonymous request rejected, authenticated request OK"

# /whoami declares RawSpec.Public:true (gate bypassed at boot scan) but is
# NOT in auth.publicRoutes — AuthMiddleware still requires a bearer under
# auth.mode=jwt. Any valid token passes; the gate is opt-out via Public:true.

show_case "GET /whoami without bearer → 401 (Public:true bypasses gate, not middleware)" \
  GET /whoami "" "" 401 MissingAuthorizationNotification

show_case "GET /whoami with noperm bearer → 200 (gate bypassed, noperm OK)" \
  GET /whoami "$TOK_NOPERM" "" 200

show_case "GET /whoami with alice bearer → 200" \
  GET /whoami "$TOK_ALICE" "" 200

sec "12. Super-admin (*:*) bypass on every write verb"

# bob carries *:* which matches every required permission. Each write verb
# on a fresh user owned by bob should succeed. The owner-check is part of
# Layer-2; bob's super-admin bypass on archive was already covered in §6 —
# here we exercise the WRITE verbs which Layer-2 does NOT gate (no
# actionName branch for them in BuildRules).

# Create a target owned by bob first so the rest of the section operates on it.
title "12.0 bob creates a target user"
if capture_post "$TOK_BOB" "bob-target@authz.test"; then
  BOB_TARGET_ID="$CAPTURE_ID"
  echo "Created bob-target id=$BOB_TARGET_ID"
  PASS=$((PASS+1))

  show_case "PUT /users/:id with bob (super-admin) → 200" \
    PUT "/users/$BOB_TARGET_ID" "$TOK_BOB" \
    '{"name":"bob-renamed","email":"bob-target@authz.test","phone":"14155559999","addresses":[]}' \
    200

  show_case "PATCH /users/:id with bob → 200" \
    PATCH "/users/$BOB_TARGET_ID" "$TOK_BOB" \
    '{"name":"bob-patched"}' 200

  show_case "PATCH /users/:id/archive with bob → 200 (no owner constraint via *:*)" \
    PATCH "/users/$BOB_TARGET_ID/archive" "$TOK_BOB" "" 200

  show_case "PATCH /users/:id/unarchive with bob → 200" \
    PATCH "/users/$BOB_TARGET_ID/unarchive" "$TOK_BOB" "" 200

  # Final delete keeps the test data clean.
  show_case "DELETE /users/:id with bob → 204" \
    DELETE "/users/$BOB_TARGET_ID" "$TOK_BOB" "" 204
else
  echo "ERROR: could not create bob's target" >&2
  FAIL=$((FAIL+1))
fi

sec "13. Layer-1 ordering — invalid bearer rejected before the gate"

# Malformed tokens fail in AuthMiddleware (401 InvalidTokenNotification)
# before the gate even runs. Confirms ordering: AuthMiddleware → Gate.

show_case "POST /users with malformed bearer → 401 InvalidTokenNotification (gate not reached)" \
  POST /users "not.a.real.token" \
  '{"name":"x","email":"x@e.test","phone":"14155550000"}' \
  401 InvalidTokenNotification

show_case "GET /users with malformed bearer → 401 (gate not reached)" \
  GET /users "abc.def.ghi" "" 401 InvalidTokenNotification

sec "14. Public bypass on documentation routes"

# /docs is added to publicRoutes automatically when the framework registers
# OpenAPI (CLAUDE.md). Confirm both anonymous AND noperm reach it.

show_case "GET /docs without bearer → 200" \
  GET /docs "" "" 200

show_case "GET /docs with noperm bearer → 200" \
  GET /docs "$TOK_NOPERM" "" 200

sec "15. Field-level read access — Phone is admin-only (ReadCriteria.Restrict)"

# FindUserByParamsQuery.ToCriteria restricts the Phone field to principals
# carrying users:admin: a non-admin gets Phone scrubbed from the read (absent in
# JSON + CSV/XLSX), and an active ?fields=phone returns 403. Create a user (with
# a phone) and wait for the CDC pipeline to materialize it into the read view.
FA_EMAIL="fieldaccess-${RANDOM}@authz.test"
if capture_post "$TOK_BOB" "$FA_EMAIL"; then
  if wait_for_user_in_view "$TOK_BOB" "$FA_EMAIL"; then
    # bob carries *:* → HasPermission("users:admin") → Phone is NOT restricted.
    assert_phone_visibility "GET /users as bob (admin via *:*) → phone PRESENT" "$TOK_BOB" present
    # alice lacks users:admin → Phone scrubbed from the read (passive omission).
    assert_phone_visibility "GET /users as alice (non-admin) → phone ABSENT" "$TOK_ALICE" absent
    # alice ACTIVELY asking for the restricted field → 403.
    show_case "GET /users?fields=phone as alice (non-admin) → 403 FieldAccessForbiddenNotification" \
      GET "/users?fields=phone" "$TOK_ALICE" "" 403 FieldAccessForbiddenNotification
  else
    title "15 — CDC did not materialize the field-access user in time"
    printf '\033[1;31mFAIL\033[0m\n'; FAIL=$((FAIL+1))
  fi
else
  title "15 — could not create the field-access user"
  printf '\033[1;31mFAIL\033[0m\n'; FAIL=$((FAIL+1))
fi

sec "16. GraphQL surface carries the same Layer-1 permission gate"

# GraphQL is its own web surface (POST /graphql) but reuses the same handlers
# AND the same declarative gate: each field declares fwgraphql.RequirePermission
# (web/graphql_routes.go), enforced under the SAME auth.authorization.enabled
# switch. The endpoint is authenticated by AuthMiddleware (no bearer → 401, REST
# envelope) and then gated per field (denied → HTTP 200 with
# MissingPermissionNotification in errors[].extensions). Matrix mirrors REST:
# users(read) / createUser(write) / deleteUser(delete).

# Authentication layer first: no bearer → 401 from AuthMiddleware (REST shape),
# the gate is never reached — so the existing show_case (status + messages[] key)
# is the right tool here.
show_case "POST /graphql without bearer → 401 (AuthMiddleware, before the gate)" \
  POST /graphql "" '{"query":"{ users(first: 1) { totalCount } }"}' \
  401 MissingAuthorizationNotification

# Layer-1 gate: noperm authenticates but carries no permission claim.
show_gql_case "GraphQL users query with noperm → MissingPermissionNotification (needs users:read)" \
  "$TOK_NOPERM" 'query { users(first: 1) { totalCount } }' \
  MissingPermissionNotification

show_gql_case "GraphQL createUser with noperm → MissingPermissionNotification (needs users:write)" \
  "$TOK_NOPERM" 'mutation { createUser(input: { name: "x", email: "x@e.test", phone: "14155550000", addresses: [] }) { id } }' \
  MissingPermissionNotification

# alice carries users:read → the read field resolves (gate passes).
show_gql_case "GraphQL users query with alice → ALLOW (alice has users:read)" \
  "$TOK_ALICE" 'query { users(first: 1) { totalCount } }' \
  ALLOW

# alice lacks users:delete → deleteUser is gated even though she can read/write.
show_gql_case "GraphQL deleteUser with alice → MissingPermissionNotification (alice lacks users:delete)" \
  "$TOK_ALICE" 'mutation { deleteUser(id: "00000000-0000-0000-0000-000000000000") { success } }' \
  MissingPermissionNotification

# Field-level read access (Layer-3-adjacent) on GraphQL: ToCriteria restricts
# Phone to admins. alice has users:read (Layer-1 passes) but NOT users:admin, so
# EXPLICITLY selecting `phone` in the node now trips the same
# FieldAccessForbiddenNotification the REST ?fields=phone returns — the GraphQL
# selection set is mapped to ReadCriteria.Projection before ToCriteria. NOT
# selecting it resolves (the field is passively scrubbed, never leaked).
show_gql_case "GraphQL users{phone} with alice (non-admin) → FieldAccessForbiddenNotification" \
  "$TOK_ALICE" 'query { users(first: 1) { edges { node { phone } } } }' \
  FieldAccessForbiddenNotification

show_gql_case "GraphQL users{name} with alice → ALLOW (no restricted field selected)" \
  "$TOK_ALICE" 'query { users(first: 1) { edges { node { name } } } }' \
  ALLOW

sec "Summary"
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
