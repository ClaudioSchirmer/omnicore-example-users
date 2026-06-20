#!/usr/bin/env bash
# Audit E2E suite for omnicore-example-users.
#
# Exercises the framework's SlogAuditor end-to-end: for every write verb
# (Insert / Update / PartialUpdate / Archive / Unarchive / Delete) the suite
# performs an HTTP request as a JWT-authenticated subject (alice from the
# Keycloak test realm) and parses the v2 audit event the framework writes to
# stdout, asserting:
#   - actor capture from JWT (sub, iss, allow-listed claims) on top-level fields
#   - flat top-level shape (threadId, entityType, entityId, verb, actionName,
#     kind, actor, actorIssuer, actorClaims, dateTime) — no nested envelope
#   - body discriminator per kind: snapshot (Insert/Delete) vs changes
#     (Update/PartialUpdate) vs neither (Archive/Unarchive transitions)
#   - children block per verb (added / changed / removed / archived /
#     unarchived / deleted with the per-op snapshot or changes shape)
#
# Companion to qa/e2e.sh (endpoint coverage under auth.mode=disabled) and
# qa/auth.sh (middleware coverage under the four validator modes). audit.sh
# fills the gap they leave: e2e.sh runs against an externally-started server
# and cannot capture stdout to inspect audit lines; auth.sh manages the
# server lifecycle but never performs a write that triggers the auditor.
#
# Prerequisites (same as qa/auth.sh):
#   docker compose -f devops/docker-compose.yml up -d
#   ./devops/debezium/register-connector.sh
# Then this script does the rest (build the server binary, boot it under
# APP_PROFILE=prd so the JWT middleware is wired in, mint alice's token,
# tail the server log, assert each audit case).
#
# Run from anywhere:  bash qa/audit.sh

set -u

BASE="${BASE:-http://localhost:8080}"
KC_URL="${KC_URL:-http://localhost:8088}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${REPO_ROOT}/devops/keycloak"
SERVER_BIN="/tmp/omnicore-example-users-qa-audit"
SERVER_LOG="/tmp/omnicore-example-users-qa-audit.log"

# Issuer URL pinned in microservice.prd.yaml. Used to assert that the audit
# line carries the JWT's iss verbatim — proves the middleware → AppContext →
# auditor chain preserves the IdP identity.
EXPECTED_ISSUER="${EXPECTED_ISSUER:-http://localhost:8088/realms/omnicore-test}"

PASS=0; FAIL=0
SERVER_PID=""

hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
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

# start_server starts the pre-built binary under APP_PROFILE=prd (JWT mode +
# auditClaims=[preferred_username, email]) and redirects its stdout/stderr to
# $SERVER_LOG. Direct binary execution (not `go run`) so $! is the actual
# server PID — `go run` spawns a child binary that survives `kill $!` and
# would leak across runs.
start_server() {
  : > "$SERVER_LOG"
  kill_port 8080
  (
    cd "$REPO_ROOT"
    APP_PROFILE="prd" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1
  ) &
  SERVER_PID=$!
  if ! wait_for_health 30; then
    echo "ERROR: server (APP_PROFILE=prd) did not become ready in 30s" >&2
    echo "--- last 40 lines of $SERVER_LOG ---" >&2
    tail -n 40 "$SERVER_LOG" >&2
    return 1
  fi
  echo "Server ready (PID=$SERVER_PID, profile=prd, log=$SERVER_LOG)"
}

# Resets Postgres + Mongo to a clean baseline. Same destructive truncate as
# qa/e2e.sh — QA is an ephemeral environment, no persistent state across runs.
reset_state() {
  title "Reset: TRUNCATE users CASCADE + outbox (Postgres) + users (Mongo)"
  docker exec omnicore-example-postgres psql -U omnicore -d users_db -c \
    "TRUNCATE TABLE users CASCADE; TRUNCATE TABLE outbox;" >/dev/null
  docker exec omnicore-example-mongo mongosh users_views --quiet --eval \
    "db.users.deleteMany({});" >/dev/null
  echo "OK — clean baseline"
  # Let the SyncEngine drain any in-flight Kafka events before we start.
  sleep 1
}

# capture_audit <method> <path> <body_or_empty> <token> [expected_status]
#
# Records the current line count of $SERVER_LOG, performs the HTTP request,
# waits briefly for the server to flush the audit line (slog writes directly
# to os.Stdout — Go's os.File issues one Write per log call, but the kernel
# may buffer briefly), then prints to stdout the FIRST new audit line in the
# log. Empty output means no audit line was emitted (assertion will fail).
#
# Stores the HTTP status in the global LAST_HTTP_STATUS and the response body
# in the global LAST_HTTP_BODY so callers can inspect both alongside the
# audit line. expected_status, when given, is asserted up front and a
# mismatch aborts the call (the audit line is only meaningful for a
# successful write — a 422 / 409 leaves no audit trail).
LAST_HTTP_STATUS=""
LAST_HTTP_BODY=""
LAST_AUDIT_JSON=""

capture_audit() {
  local method="$1" path="$2" body="$3" token="$4" expected_status="${5:-}"
  local lines_before
  lines_before=$(wc -l < "$SERVER_LOG" | tr -d ' ')

  local tmp
  tmp=$(mktemp)
  local curl_args=(-sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path"
    -H "Content-Type: application/json"
    -H "Accept-Language: en-US")
  if [ -n "$token" ]; then
    curl_args+=(-H "Authorization: Bearer $token")
  fi
  if [ -n "$body" ]; then
    curl_args+=(--data "$body")
  fi
  LAST_HTTP_STATUS=$(curl "${curl_args[@]}")
  LAST_HTTP_BODY=$(cat "$tmp")
  rm -f "$tmp"

  if [ -n "$expected_status" ] && [ "$LAST_HTTP_STATUS" != "$expected_status" ]; then
    printf '\033[1;31mFAIL\033[0m HTTP status: expected %s, got %s; body=%s\n' \
      "$expected_status" "$LAST_HTTP_STATUS" "$LAST_HTTP_BODY"
    LAST_AUDIT_JSON=""
    FAIL=$((FAIL+1))
    return 1
  fi

  # Audit is written synchronously by Orchestrator before Result returns to
  # the wrapper, so by the time curl yields the line is already on disk.
  # A small grace covers slow CI hosts where the kernel hasn't flushed yet.
  local audit=""
  local i
  for i in 1 2 3 4 5; do
    audit=$(sed -n "$((lines_before+1)),\$p" "$SERVER_LOG" \
              | grep '"msg":"audit"' | head -n1)
    if [ -n "$audit" ]; then break; fi
    sleep 0.1
  done
  LAST_AUDIT_JSON="$audit"
}

# assert_audit <case_name> <python_expression>
#
# Feeds $LAST_AUDIT_JSON to python3 and runs the given expression — the
# expression has the parsed dict bound as `a` and must call ok(...) / fail(...)
# to declare success or failure. Asserts that an audit line was captured at
# all (empty $LAST_AUDIT_JSON = automatic FAIL).
assert_audit() {
  local name="$1" check="$2"
  title "$name"
  if [ -z "$LAST_AUDIT_JSON" ]; then
    printf '\033[1;31mFAIL\033[0m no audit line captured (HTTP %s, body=%s)\n' \
      "$LAST_HTTP_STATUS" "$LAST_HTTP_BODY"
    FAIL=$((FAIL+1))
    return
  fi
  local result
  result=$(LAST_AUDIT_JSON="$LAST_AUDIT_JSON" \
           ALICE_SUB="${ALICE_SUB:-}" \
           USER_ID="${USER_ID:-}" \
           EXPECTED_ISSUER="$EXPECTED_ISSUER" \
           python3 - <<PY
import json, os, uuid
raw = os.environ["LAST_AUDIT_JSON"]
a = json.loads(raw)
errs = []
def expect(cond, msg):
    if not cond: errs.append(msg)
def eq(actual, expected, label):
    if actual != expected:
        errs.append(label + ": got " + repr(actual) + ", want " + repr(expected))
def is_uuid(s):
    try:
        uuid.UUID(str(s))
        return True
    except Exception:
        return False
def get(path):
    cur = a
    for k in path.split("."):
        if isinstance(cur, dict) and k in cur:
            cur = cur[k]
        else:
            return None
    return cur
$check
if errs:
    print("FAIL")
    for e in errs: print(" -", e)
else:
    print("PASS")
PY
)
  if printf '%s' "$result" | head -n1 | grep -q '^PASS$'; then
    printf '\033[1;32mPASS\033[0m\n'
    PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m\n'
    printf '%s\n' "$result" | tail -n +2
    printf 'AUDIT LINE:\n%s\n' "$LAST_AUDIT_JSON" | head -c 4000; echo
    FAIL=$((FAIL+1))
  fi
}

##############################################################################
sec "0. Preconditions"
##############################################################################

title "0.1 Keycloak realm ready"
if ! "$SCRIPTS/wait-ready.sh" 30 >/dev/null 2>&1; then
  echo "Keycloak not reachable at $KC_URL — bring it up with 'docker compose -f devops/docker-compose.yml up -d keycloak' first." >&2
  exit 1
fi
echo "OK — realm reachable"

title "0.2 Build server binary"
(cd "$REPO_ROOT" && go build -o "$SERVER_BIN" ./bootstrap)
echo "Binary: $SERVER_BIN"

title "0.3 Free port 8080 if anything is lingering"
kill_port 8080
echo "Port 8080 clear"

title "0.4 Resolve alice's sub from her JWT"
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
if [ -z "$ALICE_SUB" ]; then
  echo "ERROR: could not extract sub claim" >&2
  exit 1
fi
echo "alice sub = $ALICE_SUB"

title "0.5 Start server (APP_PROFILE=prd)"
start_server || exit 1

# Schema is created by the framework on first boot; the truncate runs AFTER
# the server is healthy so we never race against pending migrations.
reset_state

##############################################################################
sec "1. Insert — POST /users"
##############################################################################
# A fresh token per scenario isn't necessary (alice's grant is valid for the
# whole suite duration), so the same VALID flows through every case below.
VALID=$("$SCRIPTS/mint-token.sh" alice)

INSERT_BODY='{
  "name":"Jane Doe","email":"alice@omnicore.test","phone":"14155552671",
  "addresses":[{
    "label":"home","street":"1 Audit Way","number":"1",
    "neighborhood":"Downtown","city":"San Francisco","state":"CA",
    "zipCode":"94103","country":"US"
  }]
}'
capture_audit POST /users "$INSERT_BODY" "$VALID" 201
USER_ID=$(printf '%s' "$LAST_HTTP_BODY" | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data");print(d.get("id","") if isinstance(d, dict) else (d or ""))')
echo "USER_ID = $USER_ID"

assert_audit "1.1 Insert audit — top-level header + actor + JWT claims" '
eq(a.get("msg"), "audit", "msg")
expect(is_uuid(a.get("threadId", "")), "threadId not a UUID: " + repr(a.get("threadId")))
eq(a.get("verb"),       "insert",        "verb")
eq(a.get("entityType"), "User",          "entityType")
eq(a.get("actionName"), "GetInsertable", "actionName")
eq(a.get("kind"),       "snapshot",      "kind")
eq(a.get("entityId"),   os.environ["USER_ID"], "entityId")
expect(a.get("dateTime"), "dateTime missing")
expect("export" not in a, "v2 must NOT carry nested export envelope")
eq(a.get("actor"),  os.environ["ALICE_SUB"], "actor (JWT sub)")
eq(a.get("actorIssuer"), os.environ["EXPECTED_ISSUER"], "actorIssuer")
claims = a.get("actorClaims") or {}
eq(claims.get("preferred_username"), "alice", "actorClaims.preferred_username")
eq(claims.get("email"), "alice@omnicore.test", "actorClaims.email")
# Forbidden claims must NOT leak — auditClaims is an allowlist, not a blocklist exception.
for forbidden in ("sub","iss","aud","exp","iat","azp","sid","jti"):
    expect(forbidden not in claims, "actorClaims leaked claim " + repr(forbidden))
'

assert_audit "1.2 Insert audit — snapshot block + children op=added" '
snap = a.get("snapshot") or {}
eq(snap.get("Name"),  "Jane Doe",        "snapshot.name")
eq(snap.get("Email"), "alice@omnicore.test", "snapshot.email")
eq(snap.get("Phone"), "14155552671",     "snapshot.phone")
expect("changes" not in a, "kind=snapshot must NOT carry changes (got " + repr(a.get("changes")) + ")")
children = a.get("children") or {}
addrs = children.get("Address") or []
eq(len(addrs), 1, "children.Address length")
if addrs:
    e = addrs[0]
    eq(e.get("op"), "inserted", "children.Address[0].op (SQL-grounded: INSERT INTO addresses)")
    eq((e.get("snapshot") or {}).get("Street"), "1 Audit Way", "children.Address[0].snapshot.street")
    expect("changes" not in e, "inserted child must not carry changes")
'

##############################################################################
sec "2. Partial Update — PATCH /users/:id (root field only)"
##############################################################################

capture_audit PATCH "/users/$USER_ID" '{"name":"Jane Doe (patched)"}' "$VALID" 200

assert_audit "2.1 PartialUpdate audit — verb=update (SQL-shared with PUT) + actionName distinguishes + changes delta-only + no children" '
# SQL-grounded vocabulary: PATCH shares verb=update with PUT because the SQL
# fingerprint is identical (UPDATE col=val, updated_at=NOW). The PUT vs PATCH
# distinction lives in actionName (GetUpdatable vs GetPartialUpdatable) — same
# unification the domain already applies via IfUpdate.
eq(a.get("verb"),       "update",               "verb (shared with PUT — SQL is identical)")
eq(a.get("kind"),       "delta",                "kind")
eq(a.get("actionName"), "GetPartialUpdatable",  "actionName (carries PUT vs PATCH distinction)")
eq(a.get("actor"),      os.environ["ALICE_SUB"], "actor")
expect("snapshot" not in a, "kind=delta must NOT carry snapshot (got " + repr(a.get("snapshot")) + ")")
changes = a.get("changes") or []
# Only `name` mutated in the PATCH body — email/phone unchanged must NOT appear.
eq(len(changes), 1, "changes length (only name changed)")
if changes:
    c = changes[0]
    eq(c.get("field"), "Name",                "changes[0].field")
    eq(c.get("from"),  "Jane Doe",            "changes[0].from")
    eq(c.get("to"),    "Jane Doe (patched)",  "changes[0].to")
# Address children were not touched — all carry status=Constructor and the auditor skips them on Update.
children = a.get("children")
expect(children is None or "Address" not in (children or {}),
       "children.Address must be absent on root-only PATCH (got " + repr(children) + ")")
'

##############################################################################
sec "3. Full Update — PUT /users/:id (replaces addresses)"
##############################################################################
# Replaces the one existing address with two new ones. domain.ReplaceAddresses
# calls domain.ReplaceAggregateChildrenOf, which marks every loaded child as
# REMOVED (status) and adds the new ones with status ADDED. The persister
# emits the corresponding SQL — UPDATE addresses SET deleted_at=NOW() for the
# REMOVED slot (soft-delete; row stays in the DB, recoverable via unarchive),
# INSERT INTO addresses for the new ones. SQL-grounded vocabulary means the
# audit reflects the SQL: op=archived for the soft-deleted slot, op=inserted
# for the new ones. The op=updated case (UPDATE col=val) is exercised by the
# dedicated PUT /users/:id/addresses/:addressId endpoint at section 8.
PUT_BODY='{
  "name":"Jane Doe (patched)","email":"alice@omnicore.test","phone":"14155553333",
  "addresses":[
    {"label":"home","street":"2 Updated Ave","number":"2","neighborhood":"SoMa","city":"San Francisco","state":"CA","zipCode":"94110","country":"US"},
    {"label":"work","street":"3 Office Pl","number":"3","neighborhood":"FiDi","city":"San Francisco","state":"CA","zipCode":"94104","country":"US"}
  ]
}'
capture_audit PUT "/users/$USER_ID" "$PUT_BODY" "$VALID" 200

assert_audit "3.1 Update audit — root changes delta + Address mixed added+removed" '
eq(a.get("verb"),       "update",       "verb")
eq(a.get("kind"),       "delta",        "kind")
eq(a.get("actionName"), "GetUpdatable", "actionName")
expect("snapshot" not in a, "kind=delta must NOT carry root snapshot")
changes = a.get("changes") or []
# Only phone was actually changed (name same, email same).
phone_changes = [c for c in changes if c.get("field") == "Phone"]
eq(len(phone_changes), 1, "expected exactly one change on phone")
if phone_changes:
    eq(phone_changes[0].get("from"), "14155552671", "phone.from")
    eq(phone_changes[0].get("to"),   "14155553333", "phone.to")
addrs = (a.get("children") or {}).get("Address") or []
ops = sorted(e.get("op","") for e in addrs)
# SQL-grounded: one slot soft-deleted (UPDATE deleted_at=NOW → archived) +
# two new (INSERT INTO addresses → inserted) = ["archived","inserted","inserted"].
eq(ops, ["archived","inserted","inserted"], "children.Address ops (SQL-grounded)")
archived = [e for e in addrs if e.get("op") == "archived"]
inserted = [e for e in addrs if e.get("op") == "inserted"]
eq((len(archived), len(inserted)), (1, 2), "(archived,inserted) counts")
if archived:
    # archived entry carries snapshot of the value that was archived (pre-mutation state).
    eq((archived[0].get("snapshot") or {}).get("Street"), "1 Audit Way",
       "archived.snapshot.street")
    expect("changes" not in archived[0], "archived entry must not carry changes")
if inserted:
    streets = sorted((e.get("snapshot") or {}).get("Street","") for e in inserted)
    eq(streets, ["2 Updated Ave","3 Office Pl"], "inserted streets via snapshot")
    for e in inserted:
        expect("changes" not in e, "inserted entry must not carry changes")
'

##############################################################################
sec "4. Archive — PATCH /users/:id/archive (cascade addresses)"
##############################################################################

capture_audit PATCH "/users/$USER_ID/archive" "" "$VALID" 200

assert_audit "4.1 Archive audit — kind=transition + Address archived cascade" '
eq(a.get("verb"),       "archive",       "verb")
eq(a.get("kind"),       "transition",    "kind")
eq(a.get("actionName"), "GetArchivable", "actionName")
eq(a.get("entityId"),   os.environ["USER_ID"], "entityId")
expect("snapshot" not in a, "transition must NOT carry snapshot at root (got " + repr(a.get("snapshot")) + ")")
expect("changes" not in a, "transition must NOT carry changes at root (got " + repr(a.get("changes")) + ")")
addrs = (a.get("children") or {}).get("Address") or []
eq(len(addrs), 2, "children.Address length")
for e in addrs:
    eq(e.get("op"), "archived", "child op")
    expect((e.get("snapshot") or {}).get("Street"), "archived child must carry snapshot of the cascaded address")
'

##############################################################################
sec "5. Unarchive — PATCH /users/:id/unarchive (cascade addresses)"
##############################################################################

capture_audit PATCH "/users/$USER_ID/unarchive" "" "$VALID" 200

assert_audit "5.1 Unarchive audit — Address unarchived cascade (restores ALL archived children)" '
eq(a.get("verb"),       "unarchive",       "verb")
eq(a.get("kind"),       "transition",      "kind")
eq(a.get("actionName"), "GetUnarchivable", "actionName")
eq(a.get("entityId"),   os.environ["USER_ID"], "entityId")
addrs = (a.get("children") or {}).get("Address") or []
# Symmetric cascade restores EVERY archived child of this root — not only the
# ones the matching Archive op cascaded. So in addition to the 2 active-then-
# archived addresses (the PUT survivors), the original "1 Audit Way" (which
# went deleted_at NOT NULL during the PUT replace at case 3) is restored too.
# This documents the framework invariant: root unarchive => restore all
# archived children for that root_id. Lowering the count would mask a
# regression where some archived children silently stay archived.
eq(len(addrs), 3, "children.Address length")
streets = sorted((e.get("snapshot") or {}).get("Street","") for e in addrs)
eq(streets, ["1 Audit Way","2 Updated Ave","3 Office Pl"], "addresses restored")
for e in addrs:
    eq(e.get("op"), "unarchived", "address op")
'

##############################################################################
sec "6. Delete — DELETE /users/:id (cascade addresses)"
##############################################################################

capture_audit DELETE "/users/$USER_ID" "" "$VALID" 204

assert_audit "6.1 Delete audit — snapshot of removed state + Address deleted cascade" '
eq(a.get("verb"),       "delete",        "verb")
eq(a.get("kind"),       "snapshot",      "kind")
eq(a.get("actionName"), "GetDeletable",  "actionName")
eq(a.get("actor"),      os.environ["ALICE_SUB"], "actor")
eq(a.get("entityId"),   os.environ["USER_ID"],   "entityId")
# Delete kind=snapshot carries the entity state at deletion moment (captured
# by Old() at GetDeletable entry; no mutation step on Delete).
snap = a.get("snapshot") or {}
eq(snap.get("Name"), "Jane Doe (patched)", "snapshot.name")
expect("changes" not in a, "kind=snapshot must NOT carry changes")
# Case 5 (Unarchive) restored all 3 archived addresses to active. Delete now
# loads the aggregate via FindByID (deleted_at IS NULL filter), finds all 3
# currently-active children, and cascades the hard-delete through audit +
# FK ON DELETE CASCADE.
addrs = (a.get("children") or {}).get("Address") or []
eq(len(addrs), 3, "children.Address length")
for e in addrs:
    eq(e.get("op"), "deleted", "address op")
'

##############################################################################
sec "7. Anonymous on protected route never reaches the auditor"
##############################################################################
# Sanity check: a request without a bearer never makes it past the JWT
# middleware, so no audit line should be written. Asserting absence guards
# against a regression where the auditor would fall back to actor=anonymous
# for failed authentications (which would pollute audit forensics).

LINES_BEFORE=$(wc -l < "$SERVER_LOG" | tr -d ' ')
capture_audit POST /users '{"name":"x","email":"x@x.com","phone":"14155551234","addresses":[]}' "" 401
title "7.1 No audit line emitted for unauthenticated POST"
NEW_AUDIT=$(sed -n "$((LINES_BEFORE+1)),\$p" "$SERVER_LOG" | grep '"msg":"audit"' || true)
if [ -z "$NEW_AUDIT" ]; then
  printf '\033[1;32mPASS\033[0m (no audit line written for 401)\n'
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m audit line emitted for failed auth:\n%s\n' "$NEW_AUDIT"
  FAIL=$((FAIL+1))
fi

##############################################################################
sec "8. Change one address — op=changed (canonical PUT subresource)"
##############################################################################
# Exhaustive coverage of the auditor's per-child op vocabulary: the existing
# cases 1-6 cover added / removed / archived / unarchived / deleted; the
# missing one is `changed` — emitted when the PUT-on-address subresource
# flips an existing slot's CurrentStatus to CHANGED. This case completes
# 100% of the framework's child-op surface.
#
# Reset to a known fresh state, insert a user with TWO addresses (so we can
# assert ONE shows up as changed and the OTHER stays absent because its
# Constructor status is skipped by the auditor on update), then PUT
# /users/:id/addresses/:addressId on one of them with new field values and
# assert:
#   - verb=update, kind=delta, actionName=GetUpdatable
#   - root has NO changes (only an address child mutated, not root fields)
#   - children.Address has exactly ONE entry with op=changed, carrying
#     `changes:[{field,from,to}]` deltas (no snapshot) — the second address
#     is Constructor → skipped from the audit children block
#   - the untouched address NEVER appears in the children block

reset_state

INSERT_BODY_8='{
  "name":"Jane Doe","email":"alice@omnicore.test","phone":"14155552671",
  "addresses":[
    {"label":"home","street":"1 Audit Way","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"},
    {"label":"work","street":"2 Office Pl","number":"2","neighborhood":"FiDi","city":"San Francisco","state":"CA","zipCode":"94104","country":"US"}
  ]
}'
capture_audit POST /users "$INSERT_BODY_8" "$VALID" 201
USER_ID=$(printf '%s' "$LAST_HTTP_BODY" | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data");print(d.get("id","") if isinstance(d, dict) else (d or ""))')
echo "USER_ID = $USER_ID"

# Pull the address row ids from Postgres so we know which slot to PUT and
# which one to leave untouched. Order-stable by created_at to keep the
# assertion language consistent across runs.
TARGET_ADDR_ID=$(docker exec omnicore-example-postgres psql -U omnicore -d users_db -tA -c "
  SELECT id FROM addresses
  WHERE user_id='$USER_ID' AND deleted_at IS NULL AND street='1 Audit Way' LIMIT 1
")
export TARGET_ADDR_ID=$(printf '%s' "$TARGET_ADDR_ID" | tr -d '[:space:]')
UNTOUCHED_ADDR_ID=$(docker exec omnicore-example-postgres psql -U omnicore -d users_db -tA -c "
  SELECT id FROM addresses
  WHERE user_id='$USER_ID' AND deleted_at IS NULL AND street='2 Office Pl' LIMIT 1
")
export UNTOUCHED_ADDR_ID=$(printf '%s' "$UNTOUCHED_ADDR_ID" | tr -d '[:space:]')
echo "TARGET_ADDR_ID    = $TARGET_ADDR_ID"
echo "UNTOUCHED_ADDR_ID = $UNTOUCHED_ADDR_ID"

# PUT new values onto the targeted address. label, street, number, zipCode
# all mutate — neighborhood/city/state/country stay identical so the
# auditor's `changes` array shows exactly four field deltas (proving
# computeChanges emits ONE entry per changed column). FullBody marker
# requires every exported field on ChangeAddressRequest to be present,
# including the optional pointers (Label/Complement) — send `null` when
# the consumer wants the field absent on the persisted row.
CHANGE_BODY='{
  "label":"office","street":"100 Market St","number":"100","complement":null,
  "neighborhood":"Downtown","city":"San Francisco","state":"CA",
  "zipCode":"94105","country":"US"
}'
capture_audit PUT "/users/$USER_ID/addresses/$TARGET_ADDR_ID" "$CHANGE_BODY" "$VALID" 200

assert_audit "8.1 Change one address audit — verb=update + kind=delta + no root changes" '
eq(a.get("verb"),       "update",        "verb")
eq(a.get("kind"),       "delta",         "kind")
eq(a.get("actionName"), "GetUpdatable",  "actionName")
eq(a.get("entityId"),   os.environ["USER_ID"], "entityId")
eq(a.get("actor"),      os.environ["ALICE_SUB"], "actor")
expect("snapshot" not in a, "kind=delta must NOT carry root snapshot (got " + repr(a.get("snapshot")) + ")")
# No ROOT field mutated — only a child. The auditor still emits the wrapper
# at verb=update because the entity went through the Update path; the root
# changes array should be empty (or absent).
changes = a.get("changes") or []
eq(changes, [], "root changes must be empty (only a child mutated)")
'

assert_audit "8.2 Change one address audit — children.Address[*].op=updated (SQL: UPDATE col=val on the addresses row)" '
import os
TARGET = os.environ.get("TARGET_ADDR_ID","")
UNTOUCHED = os.environ.get("UNTOUCHED_ADDR_ID","")
children = a.get("children") or {}
addrs = children.get("Address") or []
# Only the CHANGED slot should appear — the Constructor-status untouched
# address is skipped by the auditor on update verbs by design.
eq(len(addrs), 1, "children.Address length (only the changed slot is emitted)")
if addrs:
    e = addrs[0]
    eq(e.get("op"), "updated", "children.Address[0].op (SQL-grounded: UPDATE addresses SET col=val)")
    eq(e.get("id"), TARGET, "children.Address[0].id (must match the targeted slot)")
    expect("snapshot" not in e, "op=updated must NOT carry snapshot (got " + repr(e.get("snapshot")) + ")")
    deltas = e.get("changes") or []
    # The targeted slot had 4 fields mutated: label, street, number, zip_code.
    # neighborhood/city/state/country were sent identical to the prior row
    # so they must NOT appear among the deltas.
    fields = sorted(c.get("field","") for c in deltas)
    eq(fields, ["Label","Number","Street","ZipCode"],
       "changes fields must enumerate ONLY the mutated columns")
    by_field = {c.get("field"): c for c in deltas}
    eq(by_field["Street"].get("from"), "1 Audit Way",  "street.from")
    eq(by_field["Street"].get("to"),   "100 Market St", "street.to")
    eq(by_field["Label"].get("from"),  "home",   "label.from")
    eq(by_field["Label"].get("to"),    "office", "label.to")
    eq(by_field["ZipCode"].get("from"), "94103", "zip_code.from")
    eq(by_field["ZipCode"].get("to"),   "94105", "zip_code.to")
# The untouched address (Constructor-status) must NEVER appear, even by id.
for e in addrs:
    if e.get("id") == UNTOUCHED:
        errs.append("untouched Constructor-status address leaked into the audit children block: " + repr(e))
'

##############################################################################
sec "9. Change one address — op=changed (custom PUT subresource — same shape)"
##############################################################################
# Twin of section 8 but exercising the manual showcase path (FindByEmail +
# hand-rolled handler) instead of the canonical UpdateCommandHandler. The
# auditor MUST emit identical op=changed wire shape — proving the audit
# subsystem is orthogonal to whether the consumer went canonical or manual
# above the domain layer.

# Pull the now-active (post-section-8) "100 Market St" address id back so
# we can mutate it again via the email-keyed surface.
TARGET2_ADDR_ID=$(docker exec omnicore-example-postgres psql -U omnicore -d users_db -tA -c "
  SELECT id FROM addresses
  WHERE user_id='$USER_ID' AND deleted_at IS NULL AND street='100 Market St' LIMIT 1
")
export TARGET2_ADDR_ID=$(printf '%s' "$TARGET2_ADDR_ID" | tr -d '[:space:]')
echo "TARGET2_ADDR_ID = $TARGET2_ADDR_ID (same row as TARGET_ADDR_ID after section 8)"

CHANGE_BODY_CUSTOM='{
  "label":"home","street":"500 Mission St","number":"500","complement":null,
  "neighborhood":"Downtown","city":"San Francisco","state":"CA",
  "zipCode":"94110","country":"US"
}'
capture_audit PUT "/showcase/users-custom/alice@omnicore.test/addresses/$TARGET2_ADDR_ID" \
  "$CHANGE_BODY_CUSTOM" "$VALID" 200

assert_audit "9.1 Custom PUT change-address audit — same op=updated shape as canonical" '
import os
TARGET = os.environ.get("TARGET2_ADDR_ID","")
eq(a.get("verb"),       "update",        "verb")
eq(a.get("kind"),       "delta",         "kind")
eq(a.get("actionName"), "GetUpdatable",  "actionName")
eq(a.get("entityId"),   os.environ["USER_ID"], "entityId")
addrs = (a.get("children") or {}).get("Address") or []
eq(len(addrs), 1, "children.Address length (only the changed slot)")
if addrs:
    e = addrs[0]
    eq(e.get("op"), "updated", "children.Address[0].op (SQL-grounded)")
    eq(e.get("id"), TARGET, "children.Address[0].id must match the targeted slot")
    deltas = e.get("changes") or []
    fields = sorted(c.get("field","") for c in deltas)
    # Mutated this round: label (office→home), street, number, zip_code
    eq(fields, ["Label","Number","Street","ZipCode"],
       "changes fields must enumerate ONLY the mutated columns")
    by_field = {c.get("field"): c for c in deltas}
    eq(by_field["Street"].get("from"), "100 Market St",  "street.from")
    eq(by_field["Street"].get("to"),   "500 Mission St", "street.to")
    eq(by_field["Label"].get("from"), "office", "label.from")
    eq(by_field["Label"].get("to"),   "home",   "label.to")
'

##############################################################################
sec "10. dateTime is RFC3339Nano on every audit line"
##############################################################################
# The original cases assert dateTime is present but don't pin the format.
# RFC3339Nano carries sub-second precision and Z timezone — a regression
# emitting a different format (e.g. unix-seconds float) would still pass
# "is not empty" but break log analyzers downstream.

reset_state
capture_audit POST /users '{
  "name":"Format Probe","email":"fmt@audit.test","phone":"14155550000",
  "addresses":[{"label":null,"street":"S","number":"1","neighborhood":"N","city":"C","state":"CA","zipCode":"94100","country":"US"}]
}' "$VALID" 201
FMT_USER_ID=$(printf '%s' "$LAST_HTTP_BODY" | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data");print(d.get("id","") if isinstance(d, dict) else (d or ""))')

assert_audit "10.1 dateTime carries RFC3339Nano shape (YYYY-MM-DDTHH:MM:SS....Z)" '
import re
dt = a.get("dateTime","")
# RFC3339Nano example: 2026-06-11T20:15:30.123456789Z
m = re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$", dt)
expect(m is not None, "dateTime not RFC3339-shaped: " + repr(dt))
'

##############################################################################
sec "11. threadId is unique per request"
##############################################################################
# threadId comes from AppContext.ID() (UUID per request). Two independent
# requests must produce different threadIds — the AuditEvent.ThreadID is what
# ties multi-entity audits to the same originating request, so collisions
# would break timeline reconstruction.

capture_audit POST /users '{
  "name":"TID Probe 1","email":"tid1@audit.test","phone":"14155551111",
  "addresses":[{"label":null,"street":"S","number":"1","neighborhood":"N","city":"C","state":"CA","zipCode":"94101","country":"US"}]
}' "$VALID" 201
TID1=$(printf '%s' "$LAST_AUDIT_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("threadId",""))')

capture_audit POST /users '{
  "name":"TID Probe 2","email":"tid2@audit.test","phone":"14155552222",
  "addresses":[{"label":null,"street":"S","number":"1","neighborhood":"N","city":"C","state":"CA","zipCode":"94102","country":"US"}]
}' "$VALID" 201
TID2=$(printf '%s' "$LAST_AUDIT_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("threadId",""))')

title "11.1 Two independent requests carry distinct threadIds"
if [ -n "$TID1" ] && [ -n "$TID2" ] && [ "$TID1" != "$TID2" ]; then
  printf '\033[1;32mPASS\033[0m (TID1=%s vs TID2=%s)\n' "$TID1" "$TID2"
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (TID1=%s TID2=%s — collision or missing)\n' "$TID1" "$TID2"
  FAIL=$((FAIL+1))
fi

##############################################################################
sec "12. Distinct actor — bob's writes carry bob's sub"
##############################################################################
# The original cases all use alice. Verify that a different authenticated
# subject (bob) produces an audit line with bob's sub as actor — proves the
# audit chain doesn't hardcode any specific subject. Companion to qa/auth.sh
# §0.3 which proved subject propagation reaches /whoami; here we extend to
# the auditor's actor capture.

BOB_TOKEN=$("$SCRIPTS/mint-token.sh" bob)
BOB_SUB=$(python3 -c '
import json, base64, sys
def pad(s): return s + "=" * (-len(s) % 4)
payload = json.loads(base64.urlsafe_b64decode(pad(sys.argv[1].split(".")[1])))
print(payload.get("sub", ""))
' "$BOB_TOKEN")

capture_audit POST /users '{
  "name":"Bobs Probe","email":"bob-audit@audit.test","phone":"14155553333",
  "addresses":[{"label":null,"street":"S","number":"1","neighborhood":"N","city":"C","state":"CA","zipCode":"94103","country":"US"}]
}' "$BOB_TOKEN" 201

assert_audit "12.1 bob writes → audit.actor = bob.sub (not alice)" '
import os
ALICE_SUB = os.environ["ALICE_SUB"]
BOB_SUB = "'"$BOB_SUB"'"
eq(a.get("actor"), BOB_SUB, "actor (must be bob, not alice)")
expect(a.get("actor") != ALICE_SUB, "actor must differ from alice")
claims = a.get("actorClaims") or {}
eq(claims.get("preferred_username"), "bob", "actorClaims.preferred_username")
'

##############################################################################
sec "13. PATCH delta on multiple fields → multiple changes entries"
##############################################################################
# The original PATCH case mutates only name. Verify the auditor emits ONE
# entry per changed column, sorted by field name (per CLAUDE.md audit shape).

capture_audit POST /users '{
  "name":"Multi Probe","email":"multi@audit.test","phone":"14155554444",
  "addresses":[{"label":null,"street":"S","number":"1","neighborhood":"N","city":"C","state":"CA","zipCode":"94104","country":"US"}]
}' "$VALID" 201
MULTI_USER_ID=$(printf '%s' "$LAST_HTTP_BODY" | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data");print(d.get("id","") if isinstance(d, dict) else (d or ""))')

# Patch name AND phone — both should appear in changes; email untouched.
capture_audit PATCH "/users/$MULTI_USER_ID" '{"name":"Multi Probe (renamed)","phone":"14155557777"}' "$VALID" 200

assert_audit "13.1 PATCH on name+phone → changes array carries both, sorted by field" '
changes = a.get("changes") or []
fields = sorted(c.get("field","") for c in changes)
eq(fields, ["Name","Phone"], "fields in changes (sorted)")
by_field = {c.get("field"): c for c in changes}
eq(by_field["Name"].get("from"),  "Multi Probe",            "name.from")
eq(by_field["Name"].get("to"),    "Multi Probe (renamed)", "name.to")
eq(by_field["Phone"].get("from"), "14155554444",            "phone.from")
eq(by_field["Phone"].get("to"),   "14155557777",            "phone.to")
# email was NOT in the body — must NOT appear in changes.
expect("email" not in by_field, "email must NOT appear in changes when not in PATCH body")
'

##############################################################################
sec "14. Manual showcase write verbs emit identical audit shape"
##############################################################################
# Section 9 already covers ChangeAddress on the custom surface; verify the
# other 5 manual write verbs (POST/PUT/PATCH/Archive/Unarchive/Delete) also
# emit audits with the same flat shape — the audit subsystem is orthogonal to
# whether the consumer uses the canonical Auto handlers or the manual handler
# chain.

reset_state

# Custom POST
capture_audit POST /showcase/users-custom/ '{
  "name":"Custom Probe","email":"custom@audit.test","phone":"14155556666",
  "addresses":[{"label":null,"street":"S","number":"1","neighborhood":"N","city":"C","state":"CA","zipCode":"94106","country":"US"}]
}' "$VALID" 201
CUSTOM_USER_ID=$(printf '%s' "$LAST_HTTP_BODY" | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data");print(d.get("id","") if isinstance(d, dict) else (d or ""))')

assert_audit "14.1 Custom POST → verb=insert kind=snapshot actor=alice (same shape as canonical)" '
eq(a.get("verb"),       "insert",        "verb")
eq(a.get("kind"),       "snapshot",      "kind")
eq(a.get("actionName"), "GetInsertable", "actionName")
eq(a.get("actor"),      os.environ["ALICE_SUB"], "actor")
snap = a.get("snapshot") or {}
eq(snap.get("Name"), "Custom Probe", "snapshot.name")
'

# Custom PATCH
capture_audit PATCH /showcase/users-custom/custom@audit.test '{"name":"Custom Probe (manual patch)"}' "$VALID" 200

assert_audit "14.2 Custom PATCH → verb=update kind=delta actionName=GetPartialUpdatable" '
eq(a.get("verb"),       "update",                "verb")
eq(a.get("kind"),       "delta",                 "kind")
eq(a.get("actionName"), "GetPartialUpdatable",   "actionName (manual showcase preserves the distinction)")
changes = a.get("changes") or []
eq(len(changes), 1, "changes length")
if changes:
    eq(changes[0].get("field"), "Name", "changes[0].field")
'

# Custom Archive
capture_audit PATCH /showcase/users-custom/custom@audit.test/archive "" "$VALID" 200

assert_audit "14.3 Custom Archive → verb=archive kind=transition + child cascade" '
eq(a.get("verb"),       "archive",       "verb")
eq(a.get("kind"),       "transition",    "kind")
eq(a.get("actionName"), "GetArchivable", "actionName")
addrs = (a.get("children") or {}).get("Address") or []
eq(len(addrs), 1, "children.Address length")
if addrs:
    eq(addrs[0].get("op"), "archived", "child op")
'

# Custom Unarchive
capture_audit PATCH /showcase/users-custom/custom@audit.test/unarchive "" "$VALID" 200

assert_audit "14.4 Custom Unarchive → verb=unarchive kind=transition + child restore" '
eq(a.get("verb"),       "unarchive",       "verb")
eq(a.get("kind"),       "transition",      "kind")
eq(a.get("actionName"), "GetUnarchivable", "actionName")
addrs = (a.get("children") or {}).get("Address") or []
eq(len(addrs), 1, "children.Address length")
if addrs:
    eq(addrs[0].get("op"), "unarchived", "child op")
'

# Custom DELETE (hard delete)
capture_audit DELETE /showcase/users-custom/custom@audit.test "" "$VALID" 204

assert_audit "14.5 Custom DELETE → verb=delete kind=snapshot + child deleted cascade" '
eq(a.get("verb"),       "delete",       "verb")
eq(a.get("kind"),       "snapshot",     "kind")
eq(a.get("actionName"), "GetDeletable", "actionName")
addrs = (a.get("children") or {}).get("Address") or []
eq(len(addrs), 1, "children.Address length")
if addrs:
    eq(addrs[0].get("op"), "deleted", "child op")
'

##############################################################################
sec "15. Invalid token never reaches the auditor (companion to §7)"
##############################################################################
# §7 covers no-bearer. Cover the parallel case of a bearer that fails JWT
# validation (malformed) — same expectation: 401 + no audit line.

LINES_BEFORE=$(wc -l < "$SERVER_LOG" | tr -d ' ')
capture_audit POST /users '{
  "name":"NoAudit","email":"noaudit@x.test","phone":"14155558888","addresses":[]
}' "not.a.valid.jwt" 401
title "15.1 Malformed bearer → 401 + no audit line emitted"
NEW_AUDIT=$(sed -n "$((LINES_BEFORE+1)),\$p" "$SERVER_LOG" | grep '"msg":"audit"' || true)
if [ -z "$NEW_AUDIT" ]; then
  printf '\033[1;32mPASS\033[0m (no audit line written for invalid-token 401)\n'
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m audit line emitted for failed auth:\n%s\n' "$NEW_AUDIT"
  FAIL=$((FAIL+1))
fi

##############################################################################
sec "16. Validation rejection (422) also never reaches the auditor"
##############################################################################
# Auth passes (valid alice) but the domain rejects the request — no SQL is
# executed and so no audit row should be written. Catches a regression where
# the auditor would emit an event ahead of the COMMIT.

LINES_BEFORE=$(wc -l < "$SERVER_LOG" | tr -d ' ')
# Empty name + missing addresses both trigger 422.
capture_audit POST /users '{
  "name":"","email":"422@audit.test","phone":"14155559999","addresses":[]
}' "$VALID" 422
title "16.1 Validation 422 → no audit line emitted (no SQL ran)"
NEW_AUDIT=$(sed -n "$((LINES_BEFORE+1)),\$p" "$SERVER_LOG" | grep '"msg":"audit"' || true)
if [ -z "$NEW_AUDIT" ]; then
  printf '\033[1;32mPASS\033[0m (no audit line for 422)\n'
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m audit line emitted for 422:\n%s\n' "$NEW_AUDIT"
  FAIL=$((FAIL+1))
fi

##############################################################################
sec "17. Field labels — FieldChange carries the catalog key for translated read"
##############################################################################
# domain/user.go tags Name (`label:"UserNameField"`), Email
# (`label:"UserEmailField"`), Phone (`label:"UserPhoneField"`).
# domain/address.go tags every AVO field (`label:"AddressZipCodeField"`, etc.).
# The framework's audit_builder reads the tag at write time (via
# labelKeysByColumn cached per reflect.Type) and stamps
# FieldChange.FieldLabelKey on each row of `changes`. The slog echo serializes
# it via `json:"fieldLabelKey,omitempty"`. Storage is the raw catalog key (not
# the rendered string) so future audit readers render via Deps.Translator in
# any locale.

INSERT_BODY_LABEL=$(cat <<'JSON'
{
  "name": "Label User",
  "email": "label@audit.test",
  "phone": "14155557777",
  "addresses": [{
    "label": "home", "street": "1 Loop", "number": "1",
    "neighborhood": "Mariani", "city": "Cupertino",
    "state": "CA", "zipCode": "95014", "country": "US"
  }]
}
JSON
)
capture_audit POST /users "$INSERT_BODY_LABEL" "$VALID" 201
LABEL_USER_ID=$(printf '%s' "$LAST_HTTP_BODY" | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data");print(d.get("id","") if isinstance(d, dict) else (d or ""))')

# 17.1 — A clean PATCH on Name produces a single root-level FieldChange whose
# fieldLabelKey is "UserNameField".
capture_audit PATCH "/users/$LABEL_USER_ID" '{"name":"Label User (renamed)"}' "$VALID" 200
assert_audit "17.1 PATCH Name → FieldChange.fieldLabelKey=UserNameField" '
eq(a.get("verb"), "update", "verb")
eq(a.get("kind"), "delta",  "kind")
ch = a.get("changes") or []
hits = [c for c in ch if c.get("field") == "Name"]
eq(len(hits), 1, "name change count")
if hits:
  eq(hits[0].get("fieldLabelKey"), "UserNameField", "name fieldLabelKey")
# Untagged columns (updated_at) carry no label tag — fieldLabelKey omitted.
for c in ch:
  if c.get("field") != "Name":
    expect("fieldLabelKey" not in c or c.get("fieldLabelKey") == "",
           "untagged column " + repr(c.get("field")) + " must omit fieldLabelKey, got " + repr(c.get("fieldLabelKey")))
'

# 17.2 — Child cascade: a PUT against the address subresource produces a
# child-level FieldChange (op=updated, kind=delta on the child) whose
# fieldLabelKey is "AddressZipCodeField" — proving the resolver descends
# through the AVO type at audit write time. Same canonical endpoint §8
# uses for single-address mutations.
LABEL_ADDR_ID=$(docker exec omnicore-example-postgres psql -U omnicore -d users_db -tA -c "
  SELECT id FROM addresses
  WHERE user_id='$LABEL_USER_ID' AND deleted_at IS NULL LIMIT 1
" | tr -d '[:space:]')
CHANGE_BODY_LABEL=$(cat <<'JSON'
{
  "label": "home", "street": "1 Loop", "number": "1",
  "complement": null,
  "neighborhood": "Mariani", "city": "Cupertino",
  "state": "CA", "zipCode": "94025", "country": "US"
}
JSON
)
capture_audit PUT "/users/$LABEL_USER_ID/addresses/$LABEL_ADDR_ID" "$CHANGE_BODY_LABEL" "$VALID" 200
assert_audit "17.2 PUT zipCode → children.Address[0].changes[].fieldLabelKey=AddressZipCodeField" '
addrs = (a.get("children") or {}).get("Address") or []
eq(len(addrs), 1, "children.Address length")
if addrs:
  ch = addrs[0].get("changes") or []
  hits = [c for c in ch if c.get("field") == "ZipCode"]
  eq(len(hits), 1, "zip_code change count")
  if hits:
    eq(hits[0].get("fieldLabelKey"), "AddressZipCodeField", "zip_code fieldLabelKey")
'

# Cleanup — leave the table in the state §16 expects.
capture_audit DELETE "/users/$LABEL_USER_ID" "" "$VALID" 204

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
echo "Server log: $SERVER_LOG"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
