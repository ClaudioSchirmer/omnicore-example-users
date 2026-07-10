#!/usr/bin/env bash
# Schema evolution E2E suite for omnicore-example-users.
#
# Exercises the framework's Mongo schema evolution path end to end (the design
# documented in omnicore/tasks/mongo_schema_evolution_2.md):
#
# Phase 1 — Fresh boot under autoRun=true triggers DriftFreshInit →
#           InitRegistryOnly writes the registry row at status='done', version=1.
# Phase 2 — POST 3 users via /users; wait for the CDC pipeline (Debezium →
#           Kafka → SyncEngine) to materialize them on Mongo.
# Phase 3 — db.users.drop() simulates an operator wiping the read side.
# Phase 4 — Restart triggers DriftMongoWiped + ExecuteRebuild; status cycles
#           through 'processing' to 'done'; previous_* captures audit trail.
# Phase 5 — Clean shutdown.
#
# Extended scenarios — version evolution + flag/mode behavior:
#
# Phase 6 — Build a binary at Version(2) (patch source + go build + restore);
#           start it → DriftRebuildRequired → rebuild → registry version=2 with
#           previous_version=1 captured.
# Phase 7 — Build a binary at Version(2) + extra index → DriftArtifactOnly →
#           metadata-only RefreshRegistryArtifactOnly path (no rebuild log,
#           registry artifact_hash updated, version stays 2).
# Phase 8 — Restart the original (Version(1)) binary under
#           mongo.rebuild.allowDowngrade: true → DriftDowngrade rebuild rolls
#           registry back to version=1, previous_version=2.
# Phase 9 — Start the Version(2) binary under mongo.rebuild.autoRun: check →
#           DriftRebuildRequired under check mode → boot aborts with §14.3
#           diagnostic; registry unchanged.
#
# Companion to qa/e2e.sh (endpoint coverage under auth disabled) and the rest
# of the suite. The script manages the server lifecycle itself (build binary,
# start, kill_port-guarded boot, cleanup trap) and ALWAYS restores
# internal/infra/views.go on any exit path so a failed run never leaves the developer
# tree in a patched state.
#
# Prerequisites:
#   docker compose -f devops/docker-compose.yml up -d
#   ./devops/debezium/register-connector.sh
# Then this script does the rest.
#
# Run from anywhere:  bash qa/schema_evolution.sh

set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Backend selector (postgres|mysql via BACKEND); default = postgres.
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-schema-${BACKEND:-postgres}"
SERVER_BIN_V2="/tmp/omnicore-example-users-qa-schema-v2"
SERVER_BIN_V2_ARTIFACT="/tmp/omnicore-example-users-qa-schema-v2-artifact"
SERVER_LOG="/tmp/omnicore-example-users-qa-schema-${BACKEND:-postgres}.log"
CDC_WAIT_SEC="${CDC_WAIT_SEC:-60}"

VIEWS_SRC="$REPO_ROOT/internal/infra/views.go"
VIEWS_BAK="/tmp/omnicore-example-qa-views.go.bak"

YAML_ALLOW_DOWNGRADE="/tmp/omnicore-example-qa-schema-allowdowngrade.yaml"
YAML_CHECK_MODE="/tmp/omnicore-example-qa-schema-check.yaml"

PASS=0; FAIL=0
SERVER_PID=""
LAST_EXIT_CODE=0

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

# restore_views_source — copy the backup over the working file. Safe to call
# repeatedly; no-op if the backup does not exist. Invoked by cleanup on every
# exit path so a failed run never leaves the developer tree patched.
restore_views_source() {
  if [ -n "$VIEWS_BAK" ] && [ -f "$VIEWS_BAK" ]; then
    cp "$VIEWS_BAK" "$VIEWS_SRC"
  fi
}

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  kill_port "${HTTP_PORT:-8080}"
  restore_views_source
}
trap cleanup EXIT INT TERM

wait_for_health() {
  local timeout="${1:-30}"
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -sf -o /dev/null "$BASE/livez"; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

start_server() {
  start_server_with "$SERVER_BIN" ""
}

# start_server_with — launch a specific binary, optionally with a custom yaml
# config (OMNICORE_CONFIG_PATH). Wait for /livez to come up. The Phase 1-5
# canonical start_server() delegates here with the v1 binary + no yaml.
start_server_with() {
  local binary="${1:-$SERVER_BIN}"
  local yaml="${2:-}"
  : > "$SERVER_LOG"
  kill_port "${HTTP_PORT:-8080}"
  if [ -n "$yaml" ]; then
    (
      cd "$REPO_ROOT"
      APP_PROFILE="dev" OMNICORE_CONFIG_PATH="$yaml" exec "$binary" >>"$SERVER_LOG" 2>&1
    ) &
  else
    (
      cd "$REPO_ROOT"
      APP_PROFILE="dev" exec "$binary" >>"$SERVER_LOG" 2>&1
    ) &
  fi
  SERVER_PID=$!
  if ! wait_for_health 30; then
    echo "ERROR: server (binary=$binary yaml=${yaml:-<default>}) did not become ready in 30s" >&2
    echo "--- last 60 lines of $SERVER_LOG ---" >&2
    tail -n 60 "$SERVER_LOG" >&2
    return 1
  fi
  echo "Server ready (PID=$SERVER_PID, binary=$binary, yaml=${yaml:-<default>}, log=$SERVER_LOG)"
}

# start_expecting_abort — launch a binary that is EXPECTED to abort during
# boot (e.g. under autoRun=check with pending drift, or DriftDowngrade
# without allowDowngrade). Waits for the process to exit naturally with a
# non-zero code. Returns 0 on a clean abort, non-zero when the server got
# healthy instead.
start_expecting_abort() {
  local binary="${1:-$SERVER_BIN}"
  local yaml="${2:-}"
  : > "$SERVER_LOG"
  kill_port "${HTTP_PORT:-8080}"
  if [ -n "$yaml" ]; then
    (
      cd "$REPO_ROOT"
      APP_PROFILE="dev" OMNICORE_CONFIG_PATH="$yaml" exec "$binary" >>"$SERVER_LOG" 2>&1
    ) &
  else
    (
      cd "$REPO_ROOT"
      APP_PROFILE="dev" exec "$binary" >>"$SERVER_LOG" 2>&1
    ) &
  fi
  SERVER_PID=$!
  local deadline=$(( $(date +%s) + 20 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      wait "$SERVER_PID" 2>/dev/null
      LAST_EXIT_CODE=$?
      SERVER_PID=""
      echo "Server exited (binary=$binary yaml=${yaml:-<default>}) code=$LAST_EXIT_CODE"
      return 0
    fi
    sleep 0.3
  done
  echo "ERROR: server (binary=$binary yaml=${yaml:-<default>}) did not abort within 20s" >&2
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
  LAST_EXIT_CODE=0
  return 1
}

stop_server() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
  kill_port "${HTTP_PORT:-8080}"
}

# reset_state truncates Postgres + Mongo (and the omnicore_mongo_views
# registry row for "users") so the first boot of this run lands on a fresh
# slate.
reset_state() {
  title "Reset: wipe users+addresses+outbox + omnicore_mongo_views ($BACKEND); db.users.deleteMany (Mongo: $QA_MONGO_DB)"
  qa_db_reset_domain
  qa_db_exec "DELETE FROM omnicore_mongo_views WHERE view_name IN ('users','employees','persons');"
  qa_mongo_reset
  echo "OK — clean baseline"
  sleep 1
}

assert_eq() {
  local name="$1" expected="$2" got="$3"
  if [ "$expected" = "$got" ]; then
    PASS=$((PASS+1))
    printf '  \033[1;32m✔\033[0m %s: %s\n' "$name" "$got"
  else
    FAIL=$((FAIL+1))
    printf '  \033[1;31m✘\033[0m %s: got %q, want %q\n' "$name" "$got" "$expected"
  fi
}

assert_ne() {
  local name="$1" excluded="$2" got="$3"
  if [ "$excluded" != "$got" ]; then
    PASS=$((PASS+1))
    printf '  \033[1;32m✔\033[0m %s: %s (!= %s)\n' "$name" "$got" "$excluded"
  else
    FAIL=$((FAIL+1))
    printf '  \033[1;31m✘\033[0m %s: got %s, want != %s\n' "$name" "$got" "$excluded"
  fi
}

assert_ge() {
  local name="$1" min="$2" got="$3"
  if [ "$got" -ge "$min" ]; then
    PASS=$((PASS+1))
    printf '  \033[1;32m✔\033[0m %s: %s (>= %s)\n' "$name" "$got" "$min"
  else
    FAIL=$((FAIL+1))
    printf '  \033[1;31m✘\033[0m %s: got %s, want >= %s\n' "$name" "$got" "$min"
  fi
}

# assert_log_contains — grep the server log for a substring and count it as a
# PASS when found. Used by the abort-path tests to assert the §14.x
# diagnostic landed in the operator-visible output.
assert_log_contains() {
  local name="$1" pattern="$2"
  if grep -F -q "$pattern" "$SERVER_LOG"; then
    PASS=$((PASS+1))
    printf '  \033[1;32m✔\033[0m %s: log contains %q\n' "$name" "$pattern"
  else
    FAIL=$((FAIL+1))
    printf '  \033[1;31m✘\033[0m %s: log does NOT contain %q\n' "$name" "$pattern"
    echo "    last 40 log lines:" >&2
    tail -n 40 "$SERVER_LOG" >&2 || true
  fi
}

assert_log_not_contains() {
  local name="$1" pattern="$2"
  if grep -F -q "$pattern" "$SERVER_LOG"; then
    FAIL=$((FAIL+1))
    printf '  \033[1;31m✘\033[0m %s: log unexpectedly contains %q\n' "$name" "$pattern"
  else
    PASS=$((PASS+1))
    printf '  \033[1;32m✔\033[0m %s: log does NOT contain %q\n' "$name" "$pattern"
  fi
}

post_user() {
  local name="$1" email="$2" document="$3"
  curl -sS -X POST "$BASE/users" \
    -H "Content-Type: application/json" \
    -H "Accept-Language: en-US" \
    --data "{\"name\":\"$name\",\"email\":\"$email\",\"phone\":\"14155552671\",\"document\":\"$document\",\"userName\":\"$document\",\"addresses\":[]}" \
    -o /dev/null -w "%{http_code}"
}

count_users_via_api() {
  curl -sS "$BASE/users?limit=50" 2>/dev/null | jq '.pagination.total // (.data | length)'
}

# Reads a column from the omnicore_mongo_views registry row for "users".
# Named pg_* historically; backend-driven via qa_db_query (registry columns are
# plain text/timestamps — dialect-independent).
pg_registry_field() {
  local field="$1"
  qa_db_query "SELECT $field FROM omnicore_mongo_views WHERE view_name='users';" | tr -d ' '
}

mongo_users_count() {
  docker exec omnicore-qa-mongo mongosh "$QA_MONGO_DB" --quiet --eval \
    "print(db.users.countDocuments({}))" 2>/dev/null | tail -1 | tr -d ' '
}

# wait_until_mongo_count polls the Mongo users count every 1s until it reaches
# the expected target OR the timeout expires. Returns immediately on a hit.
# Replaces fixed sleeps after CDC-emitting operations so the test is robust
# against cold-boot variability of the Debezium → Kafka → SyncEngine pipeline
# without masking a real failure: when CDC is genuinely broken, the loop still
# times out and the downstream assert_eq fires the FAIL with the actual count.
# Args: $1 = expected count, $2 = timeout seconds (default 60).
wait_until_mongo_count() {
  local expected="$1"
  local timeout="${2:-60}"
  local elapsed=0
  local got=""
  while [ "$elapsed" -lt "$timeout" ]; do
    got=$(mongo_users_count)
    if [ "$got" = "$expected" ]; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

# ─── Source patching helpers ─────────────────────────────────────────────────
# Each helper takes the ORIGINAL views.go from the backup, applies a perl
# transform, writes the result to the working file, and verifies the patch
# landed via grep. The caller builds the binary and the script's cleanup
# trap restores the source unconditionally on every exit path.

backup_views_source() {
  cp "$VIEWS_SRC" "$VIEWS_BAK" || {
    echo "ERROR: cannot back up $VIEWS_SRC to $VIEWS_BAK" >&2
    exit 1
  }
}

# patch_views_to_version <N> — rewrite Version(?) → Version(<N>) on the
# UserView declaration. Always reads from the backup so independent patches
# do not stack. The fluent-chain dot may sit on the previous line in the
# canonical formatting (`).\n\t\tVersion(1).`), so the regex does NOT anchor
# on a leading dot.
patch_views_to_version() {
  local v="$1"
  perl -pe "s/\\bVersion\\(\\d+\\)/Version($v)/g" "$VIEWS_BAK" > "$VIEWS_SRC"
  if ! grep -q "Version($v)" "$VIEWS_SRC"; then
    echo "ERROR: patch_views_to_version did not produce Version($v) in $VIEWS_SRC" >&2
    restore_views_source
    return 1
  fi
}

# patch_views_v2_with_phone_index — bump to Version(2) AND insert
# query.Index("phone") immediately after query.Index("email"). Same
# RebuildHash as the unmodified v2 binary, different ArtifactHash — exactly
# the input shape that lands DriftArtifactOnly in the §9.1 matrix.
patch_views_v2_with_phone_index() {
  perl -0pe '
    s/\bVersion\(\d+\)/Version(2)/g;
    s|query\.Index\("email"\),|query.Index("email"),\n\t\t\tquery.Index("phone"),|;
  ' "$VIEWS_BAK" > "$VIEWS_SRC"
  if ! grep -q 'Version(2)' "$VIEWS_SRC" || ! grep -q 'Index("phone")' "$VIEWS_SRC"; then
    echo "ERROR: patch_views_v2_with_phone_index did not produce both Version(2) and Index(\"phone\")" >&2
    restore_views_source
    return 1
  fi
}

build_binary() {
  local out="$1"
  (cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS" -o "$out" ./bootstrap)
}

# ─── YAML override generators ────────────────────────────────────────────────
# Both helpers take microservice.dev.yaml as the base and write a modified
# copy to /tmp. OMNICORE_CONFIG_PATH points at the temp file so the framework
# loads the override without touching the on-disk dev.yaml. Anchored on the
# `rebuild:` block so the migrations block's `autoRun: true` is not affected.

mk_yaml_with_allow_downgrade() {
  # microservice.dev.yaml carries `allowDowngrade: false` by default under the
  # rebuild: block; substitute it for `allowDowngrade: true` so Phase 8's
  # downgrade rebuild path is exercised. Anchoring on this line keeps the awk
  # resilient to other changes in the block (autoRun, orphan, future knobs).
  awk '
    /^  rebuild:/ { in_rebuild = 1; print; next }
    in_rebuild && /^[^ \t]/ { in_rebuild = 0 }
    in_rebuild && /^    allowDowngrade: false/ {
      print "    allowDowngrade: true"
      next
    }
    { print }
  ' "$REPO_ROOT/microservice.dev.yaml" > "$YAML_ALLOW_DOWNGRADE"
  if ! grep -q "allowDowngrade: true" "$YAML_ALLOW_DOWNGRADE"; then
    echo "ERROR: mk_yaml_with_allow_downgrade did not inject the flag" >&2
    return 1
  fi
}

mk_yaml_check_mode() {
  awk '
    /^  rebuild:/ { in_rebuild = 1; print; next }
    in_rebuild && /^[^ \t]/ { in_rebuild = 0 }
    in_rebuild && /^    autoRun: true/ { print "    autoRun: check"; next }
    { print }
  ' "$REPO_ROOT/microservice.dev.yaml" > "$YAML_CHECK_MODE"
  if ! grep -q "autoRun: check" "$YAML_CHECK_MODE"; then
    echo "ERROR: mk_yaml_check_mode did not produce autoRun: check" >&2
    return 1
  fi
}

# ─── Build ───────────────────────────────────────────────────────────────────

sec "Build v1 server binary + back up views.go for patching"
backup_views_source
build_binary "$SERVER_BIN" || { echo "ERROR: v1 build failed" >&2; exit 1; }
echo "OK — v1 binary: $SERVER_BIN"
echo "OK — views.go backed up to: $VIEWS_BAK"

# ─── Phase 1: clean baseline + first boot ────────────────────────────────────

sec "Phase 1 — fresh boot under autoRun=true (DriftFreshInit)"
reset_state
start_server || exit 1

title "Verify registry row initialized"
status=$(pg_registry_field "status")
version=$(pg_registry_field "version")
assert_eq "omnicore_mongo_views.status" "done" "$status"
assert_eq "omnicore_mongo_views.version" "1" "$version"

# ─── Phase 2: POST 3 users, wait for CDC, verify ─────────────────────────────

sec "Phase 2 — POST 3 users + CDC propagation"

s1=$(post_user "Alice Smith" "alice.scm@example.test" "10000000201")
s2=$(post_user "Bob Jones"   "bob.scm@example.test"   "10000000202")
s3=$(post_user "Carol Diaz"  "carol.scm@example.test" "10000000203")
assert_eq "POST user1 status" "201" "$s1"
assert_eq "POST user2 status" "201" "$s2"
assert_eq "POST user3 status" "201" "$s3"

title "Poll Mongo until 3 users materialize (timeout ${CDC_WAIT_SEC}s) — CDC pipeline: Debezium → Kafka → SyncEngine"
wait_until_mongo_count 3 "$CDC_WAIT_SEC" || true

api_total=$(count_users_via_api)
assert_eq "GET /users count (post-CDC)" "3" "$api_total"

mongo_total=$(mongo_users_count)
assert_eq "Mongo users count (post-CDC)" "3" "$mongo_total"

# ─── Phase 3: stop server + drop Mongo collection ────────────────────────────

sec "Phase 3 — operator wipes Mongo (db.users.drop())"
stop_server
docker exec omnicore-qa-mongo mongosh "$QA_MONGO_DB" --quiet --eval "db.users.drop();" >/dev/null
echo "OK — Mongo 'users' collection dropped"

mongo_total=$(mongo_users_count)
assert_eq "Mongo users count (after drop)" "0" "$mongo_total"

status=$(pg_registry_field "status")
version=$(pg_registry_field "version")
assert_eq "omnicore_mongo_views.status (after Mongo drop)" "done" "$status"
assert_eq "omnicore_mongo_views.version (after Mongo drop)" "1" "$version"

# ─── Phase 4: restart triggers DriftMongoWiped → ExecuteRebuild ──────────────

sec "Phase 4 — restart triggers ExecuteRebuild (DriftMongoWiped + autoRun=true)"
start_server || exit 1

title "Slog should carry view.rebuild.start + view.rebuild.end events"
start_count=$(grep -c "view.rebuild.start" "$SERVER_LOG" || true)
end_count=$(grep -c "view.rebuild.end" "$SERVER_LOG" || true)
assert_ge "view.rebuild.start lines" 1 "$start_count"
assert_ge "view.rebuild.end lines" 1 "$end_count"

title "Verify Mongo collection rebuilt from PG"
mongo_total=$(mongo_users_count)
assert_eq "Mongo users count (post-rebuild)" "3" "$mongo_total"

api_total=$(count_users_via_api)
assert_eq "GET /users count (post-rebuild)" "3" "$api_total"

title "Verify registry state after rebuild — version still 1, previous_* captured"
status=$(pg_registry_field "status")
version=$(pg_registry_field "version")
prev_version=$(pg_registry_field "previous_version")
# Render the boolean predicate as 't'/'f' in SQL so it reads identically on
# Postgres (native boolean → 't') and MySQL (integer boolean → would be 1/0).
prev_applied_at_present=$(pg_registry_field "CASE WHEN previous_applied_at IS NOT NULL THEN 't' ELSE 'f' END")
started_at_cleared=$(pg_registry_field "CASE WHEN started_at IS NULL THEN 't' ELSE 'f' END")
assert_eq "omnicore_mongo_views.status (post-rebuild)" "done" "$status"
assert_eq "omnicore_mongo_views.version (post-rebuild)" "1" "$version"
assert_eq "omnicore_mongo_views.previous_version" "1" "$prev_version"
assert_eq "omnicore_mongo_views.previous_applied_at IS NOT NULL" "t" "$prev_applied_at_present"
assert_eq "omnicore_mongo_views.started_at IS NULL" "t" "$started_at_cleared"

# ─── Phase 5: shutdown ───────────────────────────────────────────────────────

sec "Phase 5 — shutdown after canonical FreshInit + MongoWiped path"
stop_server
echo "Server stopped cleanly"

# ─── Phase 6: DriftRebuildRequired (Version bump 1 → 2) ──────────────────────

sec "Phase 6 — DriftRebuildRequired via Version(1)→Version(2) bump"

title "Patch internal/infra/views.go to .Version(2), build v2 binary, restore source"
patch_views_to_version 2 || exit 1
build_binary "$SERVER_BIN_V2" || { echo "ERROR: v2 build failed" >&2; restore_views_source; exit 1; }
restore_views_source
echo "OK — v2 binary: $SERVER_BIN_V2 (source restored to Version(1))"

# Capture pre-state for diff assertions
pre_combined_hash=$(pg_registry_field "combined_hash")

start_server_with "$SERVER_BIN_V2" "" || exit 1

title "Verify rebuild fired + registry advanced to version 2"
start_count=$(grep -c "view.rebuild.start" "$SERVER_LOG" || true)
end_count=$(grep -c "view.rebuild.end" "$SERVER_LOG" || true)
assert_ge "Phase 6 view.rebuild.start lines" 1 "$start_count"
assert_ge "Phase 6 view.rebuild.end lines" 1 "$end_count"

version=$(pg_registry_field "version")
prev_version=$(pg_registry_field "previous_version")
prev_combined=$(pg_registry_field "previous_combined_hash")
new_combined=$(pg_registry_field "combined_hash")
status=$(pg_registry_field "status")
assert_eq "Phase 6 registry.version" "2" "$version"
assert_eq "Phase 6 registry.previous_version" "1" "$prev_version"
assert_eq "Phase 6 registry.previous_combined_hash" "$pre_combined_hash" "$prev_combined"
assert_ne "Phase 6 registry.combined_hash (changed by bump)" "$pre_combined_hash" "$new_combined"
assert_eq "Phase 6 registry.status" "done" "$status"

title "Sanity: docs still present + accessible via API"
mongo_total=$(mongo_users_count)
api_total=$(count_users_via_api)
assert_eq "Phase 6 Mongo users count" "3" "$mongo_total"
assert_eq "Phase 6 GET /users count" "3" "$api_total"

stop_server

# ─── Phase 7: DriftArtifactOnly (Version(2) + extra index) ───────────────────

sec "Phase 7 — DriftArtifactOnly via extra Index(\"phone\")"

title "Patch internal/infra/views.go to .Version(2) + Index(\"phone\"), build, restore source"
patch_views_v2_with_phone_index || exit 1
build_binary "$SERVER_BIN_V2_ARTIFACT" || { echo "ERROR: v2+phone build failed" >&2; restore_views_source; exit 1; }
restore_views_source
echo "OK — v2+phone binary: $SERVER_BIN_V2_ARTIFACT (source restored to Version(1))"

pre_artifact_hash=$(pg_registry_field "artifact_hash")
pre_combined_hash=$(pg_registry_field "combined_hash")
pre_rebuild_hash=$(pg_registry_field "rebuild_hash")

start_server_with "$SERVER_BIN_V2_ARTIFACT" "" || exit 1

title "Verify NO rebuild fired (metadata-only refresh) + artifact_hash advanced"
# RefreshRegistryArtifactOnly path emits no view.rebuild.* events. The Phase 4
# + Phase 6 starts already added entries; only assert that Phase 7's start
# did NOT add a NEW one.
start_count_after=$(grep -c "view.rebuild.start" "$SERVER_LOG" || true)
end_count_after=$(grep -c "view.rebuild.end" "$SERVER_LOG" || true)
# Phase 7 reuses the same log file (cleared by start_server_with) — so any
# rebuild line implies a fresh rebuild ran. Expect zero.
assert_eq "Phase 7 view.rebuild.start lines" "0" "$start_count_after"
assert_eq "Phase 7 view.rebuild.end lines" "0" "$end_count_after"

new_artifact_hash=$(pg_registry_field "artifact_hash")
new_combined_hash=$(pg_registry_field "combined_hash")
new_rebuild_hash=$(pg_registry_field "rebuild_hash")
version=$(pg_registry_field "version")
assert_eq "Phase 7 registry.version (unchanged)" "2" "$version"
assert_eq "Phase 7 registry.rebuild_hash (unchanged)" "$pre_rebuild_hash" "$new_rebuild_hash"
assert_ne "Phase 7 registry.artifact_hash (changed by index add)" "$pre_artifact_hash" "$new_artifact_hash"
assert_ne "Phase 7 registry.combined_hash (changed)" "$pre_combined_hash" "$new_combined_hash"

stop_server

# ─── Phase 8: DriftDowngrade rebuild with allowDowngrade=true ────────────────

sec "Phase 8 — DriftDowngrade rebuild under mongo.rebuild.allowDowngrade: true"

title "Generate yaml override with allowDowngrade: true"
mk_yaml_with_allow_downgrade || exit 1
echo "OK — yaml override: $YAML_ALLOW_DOWNGRADE"

pre_version=$(pg_registry_field "version")
pre_combined_hash=$(pg_registry_field "combined_hash")

start_server_with "$SERVER_BIN" "$YAML_ALLOW_DOWNGRADE" || exit 1

title "Verify downgrade rebuild fired + registry rolled back to v1"
start_count=$(grep -c "view.rebuild.start" "$SERVER_LOG" || true)
end_count=$(grep -c "view.rebuild.end" "$SERVER_LOG" || true)
assert_ge "Phase 8 view.rebuild.start lines" 1 "$start_count"
assert_ge "Phase 8 view.rebuild.end lines" 1 "$end_count"

version=$(pg_registry_field "version")
prev_version=$(pg_registry_field "previous_version")
prev_combined=$(pg_registry_field "previous_combined_hash")
assert_eq "Phase 8 registry.version (downgraded)" "1" "$version"
assert_eq "Phase 8 registry.previous_version (was v2)" "$pre_version" "$prev_version"
assert_eq "Phase 8 registry.previous_combined_hash" "$pre_combined_hash" "$prev_combined"

mongo_total=$(mongo_users_count)
assert_eq "Phase 8 Mongo users count" "3" "$mongo_total"

stop_server

# ─── Phase 9: autoRun=check abort (DriftRebuildRequired under check) ─────────

sec "Phase 9 — DriftRebuildRequired under mongo.rebuild.autoRun: check → boot abort"

title "Generate yaml override with autoRun: check"
mk_yaml_check_mode || exit 1
echo "OK — yaml override: $YAML_CHECK_MODE"

pre_version=$(pg_registry_field "version")
pre_combined_hash=$(pg_registry_field "combined_hash")

# v2 binary against v1 registry under autoRun=check → DriftRebuildRequired
# under check → §14.3 abort with the manual SQL reconcile in the diagnostic.
start_expecting_abort "$SERVER_BIN_V2" "$YAML_CHECK_MODE"
abort_status=$?
assert_eq "Phase 9 start_expecting_abort returned clean abort" "0" "$abort_status"
if [ "$LAST_EXIT_CODE" -ne 0 ]; then
  PASS=$((PASS+1))
  printf '  \033[1;32m✔\033[0m Phase 9 server exit code: %s (non-zero)\n' "$LAST_EXIT_CODE"
else
  FAIL=$((FAIL+1))
  printf '  \033[1;31m✘\033[0m Phase 9 server exit code: 0 (expected non-zero abort)\n'
fi

title "Verify §14.3 diagnostic landed in the boot log"
assert_log_contains "Phase 9 §14.3 keyword (shape drift)" "shape drift"
assert_log_contains "Phase 9 §14.3 keyword (rebuild required)" "rebuild required"
assert_log_contains "Phase 9 §14.3 keyword (manual-reconcile-rebuild)" "manual-reconcile-rebuild"
assert_log_contains "Phase 9 §14.3 keyword (autoRun=check)" "autoRun=check"

title "Verify registry was NOT updated (check mode is read-only)"
version=$(pg_registry_field "version")
new_combined_hash=$(pg_registry_field "combined_hash")
assert_eq "Phase 9 registry.version (unchanged)" "$pre_version" "$version"
assert_eq "Phase 9 registry.combined_hash (unchanged)" "$pre_combined_hash" "$new_combined_hash"

# ─── Final shutdown ──────────────────────────────────────────────────────────

sec "Phase 10 — mongo.rebuild.autoRun: false skips drift detection entirely"
###############################################################################
# autoRun: false is the operator opt-out — drift detection itself does not
# run, so even an obvious-drift state (Version bump without ApplyMongoSpecs
# action) is silently ignored and the server boots. Validates the third arm
# of the 3-mode model (check / true / false). Companion to Phase 9 (check
# mode aborts) and Phases 1-4 (true mode reconciles).
#
# Setup: build a v3 binary (no actual shape change beyond version), generate
# a yaml with autoRun: false, boot it against the existing registry (which
# is back at v1 after Phase 8). Expected: boot succeeds, registry untouched,
# no rebuild lines in the log.

YAML_FALSE_MODE="/tmp/omnicore-example-qa-schema-false.yaml"
SERVER_BIN_V3="/tmp/omnicore-example-users-qa-schema-v3"

mk_yaml_false_mode() {
  awk '
    /^  rebuild:/ { in_rebuild = 1; print; next }
    in_rebuild && /^[^ \t]/ { in_rebuild = 0 }
    in_rebuild && /^    autoRun: true/ { print "    autoRun: false"; next }
    { print }
  ' "$REPO_ROOT/microservice.dev.yaml" > "$YAML_FALSE_MODE"
  if ! grep -q "autoRun: false" "$YAML_FALSE_MODE"; then
    echo "ERROR: mk_yaml_false_mode did not produce autoRun: false" >&2
    return 1
  fi
}

title "Patch views.go to .Version(3), build v3, restore source"
backup_views_source
patch_views_to_version 3 || exit 1
build_binary "$SERVER_BIN_V3"
restore_views_source

title "Generate yaml override with autoRun: false"
mk_yaml_false_mode || exit 1

title "Capture registry baseline before the autoRun=false boot"
pre_combined_hash_p10=$(pg_registry_field combined_hash)
pre_applied_at_p10=$(pg_registry_field applied_at)
pre_version_p10=$(pg_registry_field version)
echo "Pre-boot version=$pre_version_p10 combined_hash=$pre_combined_hash_p10"

title "Start v3 binary under autoRun: false"
SERVER_LOG_P10="${SERVER_LOG}.p10"
: > "$SERVER_LOG_P10"
kill_port "${HTTP_PORT:-8080}"
(
  cd "$REPO_ROOT"
  APP_PROFILE="dev" OMNICORE_CONFIG_PATH="$YAML_FALSE_MODE" \
    exec "$SERVER_BIN_V3" >>"$SERVER_LOG_P10" 2>&1
) &
SERVER_PID=$!
SERVER_LOG="$SERVER_LOG_P10"
if ! wait_for_health 30; then
  echo "FAIL: server did not become ready under autoRun: false in 30s" >&2
  tail -n 60 "$SERVER_LOG_P10" >&2
  FAIL=$((FAIL+1))
else
  # Slog must NOT carry any rebuild start/end markers — drift detection
  # didn't run at all.
  rebuild_start_lines=$(grep -c "view.rebuild.start" "$SERVER_LOG_P10" || true)
  rebuild_end_lines=$(grep -c "view.rebuild.end" "$SERVER_LOG_P10" || true)
  assert_eq "Phase 10 view.rebuild.start lines (autoRun=false)" "0" "$rebuild_start_lines"
  assert_eq "Phase 10 view.rebuild.end lines (autoRun=false)" "0" "$rebuild_end_lines"

  # The "skipped" slog line must appear so operators see the framework
  # acknowledged the flag.
  assert_log_contains "Phase 10 skipped acknowledgement log line" \
    "view drift reconciliation skipped (autoRun=false)" \
    "$SERVER_LOG_P10"

  # Registry row stays at its prior shape — no fields advanced.
  post_combined_hash=$(pg_registry_field combined_hash)
  post_version=$(pg_registry_field version)
  assert_eq "Phase 10 registry.version (unchanged)" "$pre_version_p10" "$post_version"
  assert_eq "Phase 10 registry.combined_hash (unchanged)" "$pre_combined_hash_p10" "$post_combined_hash"
fi
stop_server

sec "Phase 11 — DriftDowngrade under allowDowngrade=false (default) aborts boot"
###############################################################################
# Phase 8 covered the allowDowngrade=true rebuild path. The complement is
# the default false: a downgrade attempt must abort with the §14.6
# diagnostic, registry stays untouched. Uses the v1 binary (which by now
# carries a registry that has cycled — last value was bumped to v3 in
# Phase 10? Actually Phase 10 did NOT bump the registry — autoRun=false
# means nothing changed in the registry, so it's still at whatever Phase 9
# left it).
#
# Wait — Phase 9 also didn't change the registry (check mode aborts). So
# the registry is still at v1 (rolled back by Phase 8). We need to bump
# the registry to v2 first so a v1 boot is detectably a downgrade.
#
# Strategy: bump via Phase 6's v2 binary (autoRun=true). Then attempt v1
# boot under default yaml — must abort with §14.6 diagnostic.

title "Bump registry to v2 first so v1 is a downgrade target"
SERVER_LOG_P11_PREP="${SERVER_LOG}.p11.prep"
: > "$SERVER_LOG_P11_PREP"
kill_port "${HTTP_PORT:-8080}"
(
  cd "$REPO_ROOT"
  APP_PROFILE="dev" exec "$SERVER_BIN_V2" >>"$SERVER_LOG_P11_PREP" 2>&1
) &
SERVER_PID=$!
SERVER_LOG="$SERVER_LOG_P11_PREP"
if wait_for_health 30; then
  prep_version=$(pg_registry_field version)
  if [ "$prep_version" = "2" ]; then
    echo "Registry now at version=2 — ready for v1 downgrade attempt"
  else
    echo "WARN: expected registry version=2 after Phase 11 prep, got $prep_version" >&2
  fi
fi
stop_server

title "Attempt to boot v1 binary against v2 registry — expect §14.6 abort"
SERVER_LOG_P11="${SERVER_LOG_BASE:-/tmp/omnicore-example-users-qa-schema.log}.p11"
: > "$SERVER_LOG_P11"
kill_port "${HTTP_PORT:-8080}"
(
  cd "$REPO_ROOT"
  APP_PROFILE="dev" exec "$SERVER_BIN" >>"$SERVER_LOG_P11" 2>&1
) &
SERVER_PID=$!
SERVER_LOG="$SERVER_LOG_P11"

# Boot should NOT become healthy — wait briefly and assert /livez fails.
sleep 4
if curl -sf -o /dev/null "$BASE/livez"; then
  printf '\033[1;31mFAIL\033[0m Phase 11 — v1 boot under default allowDowngrade=false should have aborted but /livez responded 200\n'
  FAIL=$((FAIL+1))
  stop_server
else
  printf '\033[1;32mPASS\033[0m Phase 11 — v1 boot under default allowDowngrade=false did NOT serve /livez (abort path)\n'
  PASS=$((PASS+1))

  # Slog should carry the downgrade diagnostic.
  if grep -q "deployed code is older than the registry state" "$SERVER_LOG_P11"; then
    printf '\033[1;32mPASS\033[0m Phase 11 — §14.6 diagnostic message found in boot log\n'
    PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m Phase 11 — expected §14.6 diagnostic in boot log, not found\n'
    tail -n 30 "$SERVER_LOG_P11"
    FAIL=$((FAIL+1))
  fi

  # Registry must NOT have been altered.
  p11_version=$(pg_registry_field version)
  assert_eq "Phase 11 registry.version unchanged after abort" "2" "$p11_version"
fi
# The aborted server may still be in the PID; force-kill.
kill_port "${HTTP_PORT:-8080}"

sec "Phase 12a — DriftAlienData: populated Mongo + NO registry row → abort (autoRun cannot escape)"
###############################################################################
# The one drift case autoRun CANNOT auto-resolve in either direction: the
# Mongo collection carries documents but there is no registry row to certify
# them. The framework refuses to rebuild (would clobber possibly-legit data)
# AND refuses to adopt (can't prove the docs match the current shape). Aborts
# under autoRun ∈ {check, true}. Reproduced by seeding a clean v1 view, then
# deleting ONLY the registry row while leaving the Mongo docs in place.

title "Reset to a clean baseline and boot v1 (autoRun=true) to seed a certified view"
qa_db_reset_domain
qa_db_exec "DELETE FROM omnicore_mongo_views WHERE view_name IN ('users','employees','persons');"
qa_mongo_reset
start_server_with "$SERVER_BIN" "" || exit 1
s_alien=$(post_user "Alien Seed" "alien.seed@example.com" "39000004001")
assert_eq "Phase 12a seed POST status" "201" "$s_alien"
title "Poll Mongo until the seed doc materializes"
alien_ready=fail
for _ in $(seq 1 "${CDC_WAIT_SEC:-30}"); do
  [ "$(mongo_users_count)" -ge 1 ] 2>/dev/null && { alien_ready=ok; break; }
  sleep 1
done
assert_eq "Phase 12a seed materialized in Mongo" "ok" "$alien_ready"
stop_server

title "Delete ONLY the registry row (Mongo docs survive) → the alien-data condition"
qa_db_exec "DELETE FROM omnicore_mongo_views WHERE view_name='users';"
registry_gone=$(qa_db_query "SELECT count(*) FROM omnicore_mongo_views WHERE view_name='users';" | tr -d ' ')
assert_eq "Phase 12a registry row removed" "0" "$registry_gone"
mongo_survives=$(mongo_users_count)
assert_ge "Phase 12a Mongo docs still present" 1 "$mongo_survives"

title "Boot v1 under autoRun=check → DriftAlienData abort + §14.4 diagnostic"
start_expecting_abort "$SERVER_BIN" "$YAML_CHECK_MODE"
assert_eq "Phase 12a start_expecting_abort returned cleanly" "0" "$?"
if [ "$LAST_EXIT_CODE" -ne 0 ]; then
  PASS=$((PASS+1)); printf '  \033[1;32m✔\033[0m Phase 12a exit code %s (non-zero abort)\n' "$LAST_EXIT_CODE"
else
  FAIL=$((FAIL+1)); printf '  \033[1;31m✘\033[0m Phase 12a exited 0 (expected abort)\n'
fi
assert_log_contains "Phase 12a alien-data keyword (cannot certify)" "cannot certify"
assert_log_contains "Phase 12a alien-data keyword (no registry row)" "no registry row"
assert_log_contains "Phase 12a alien-data remedy (manual-reconcile-tofu)" "manual-reconcile-tofu"

title "Verify the registry stayed empty (abort is read-only)"
still_gone=$(qa_db_query "SELECT count(*) FROM omnicore_mongo_views WHERE view_name='users';" | tr -d ' ')
assert_eq "Phase 12a registry still absent after abort" "0" "$still_gone"

sec "Phase 12b — DriftForgotToBump: shape changed without a Version() bump → abort"
###############################################################################
# The developer-intent guard: the registry version EQUALS the spec version but
# the combined hash differs — the view shape changed in code without bumping
# Version(N). autoRun cannot resolve it (the integer is the only intent
# signal), so it aborts regardless of mode. Reproduced by seeding a clean v1
# registry, then booting a binary that adds Index("phone") while KEEPING
# Version(1).

title "Reset + boot the plain v1 binary to write a v1 registry row"
qa_db_reset_domain
qa_db_exec "DELETE FROM omnicore_mongo_views WHERE view_name IN ('users','employees','persons');"
qa_mongo_reset
start_server_with "$SERVER_BIN" "" || exit 1
fb_version=$(pg_registry_field version)
assert_eq "Phase 12b baseline registry.version" "1" "$fb_version"
fb_pre_combined=$(pg_registry_field combined_hash)
stop_server

title "Build a Version(1)+DeleteOnArchive() binary — same version, REBUILD-relevant shape change"
# A rebuild-relevant change (deleteOnArchive is in RebuildHash) at the SAME
# Version is what lands DriftForgotToBump. An index add would only touch the
# ArtifactHash → DriftArtifactOnly, a different (auto-resolvable) case. Inject
# .DeleteOnArchive() right after the users view's Version(1). so only the
# document-shape hash moves while the version integer stays put.
backup_views_source
perl -0pe 's|(View\("users"\)\.\s*\n\s*Version\(1\)\.)|$1\n\t\tDeleteOnArchive().|' \
  "$VIEWS_BAK" > "$VIEWS_SRC"
if ! grep -q 'DeleteOnArchive()' "$VIEWS_SRC" || ! grep -q 'Version(1)' "$VIEWS_SRC"; then
  echo "ERROR: forgot-to-bump patch did not keep Version(1) + add DeleteOnArchive()" >&2
  restore_views_source; exit 1
fi
SERVER_BIN_FORGOT="/tmp/omnicore-example-users-qa-schema-forgot"
build_binary "$SERVER_BIN_FORGOT" || { restore_views_source; echo "ERROR: forgot-to-bump build failed" >&2; exit 1; }
restore_views_source
echo "OK — Version(1)+phone binary: $SERVER_BIN_FORGOT (source restored)"

title "Boot it under autoRun=check → DriftForgotToBump abort + §14.5 diagnostic"
start_expecting_abort "$SERVER_BIN_FORGOT" "$YAML_CHECK_MODE"
assert_eq "Phase 12b start_expecting_abort returned cleanly" "0" "$?"
if [ "$LAST_EXIT_CODE" -ne 0 ]; then
  PASS=$((PASS+1)); printf '  \033[1;32m✔\033[0m Phase 12b exit code %s (non-zero abort)\n' "$LAST_EXIT_CODE"
else
  FAIL=$((FAIL+1)); printf '  \033[1;31m✘\033[0m Phase 12b exited 0 (expected abort)\n'
fi
assert_log_contains "Phase 12b forgot-to-bump keyword (without bumping Version)" "without bumping Version"
assert_log_contains "Phase 12b forgot-to-bump remedy (bump the Version)" "bump the Version"

title "Registry unchanged after the abort (version + hash intact)"
fb_post_version=$(pg_registry_field version)
fb_post_combined=$(pg_registry_field combined_hash)
assert_eq "Phase 12b registry.version unchanged" "1" "$fb_post_version"
assert_eq "Phase 12b registry.combined_hash unchanged" "$fb_pre_combined" "$fb_post_combined"

sec "Phase 13 — OMNICORE_CODE_VERSION env stamps the registry row"
###############################################################################
# The framework stamps the env var (when set) on the registry's code_version
# column at write time. Run a fresh init with the env var set and assert it
# round-trips. Combined with Phase 1's blank-baseline behavior, locks the
# end-to-end contract.

title "Reset registry + Mongo so the next boot is a true DriftFreshInit"
qa_db_reset_domain
qa_db_exec "DELETE FROM omnicore_mongo_views WHERE view_name IN ('users','employees','persons');"
qa_mongo_reset

title "Start v1 with OMNICORE_CODE_VERSION=qa-test-deploy-abc set"
SERVER_LOG_P12="${SERVER_LOG_BASE:-/tmp/omnicore-example-users-qa-schema.log}.p12"
: > "$SERVER_LOG_P12"
kill_port "${HTTP_PORT:-8080}"
(
  cd "$REPO_ROOT"
  APP_PROFILE="dev" OMNICORE_CODE_VERSION="qa-test-deploy-abc" \
    exec "$SERVER_BIN" >>"$SERVER_LOG_P12" 2>&1
) &
SERVER_PID=$!
SERVER_LOG="$SERVER_LOG_P12"
if ! wait_for_health 30; then
  echo "FAIL: server did not become ready in Phase 12" >&2
  tail -n 40 "$SERVER_LOG_P12" >&2
  FAIL=$((FAIL+1))
else
  registry_code_version=$(pg_registry_field code_version)
  assert_eq "Phase 12 registry.code_version stamped from env" \
    "qa-test-deploy-abc" "$registry_code_version"
fi

sec "Final shutdown"
stop_server
echo "Server stopped cleanly"

# ─── Summary ─────────────────────────────────────────────────────────────────

hr
printf '\033[1;37mResults: \033[0m\033[1;32m%d PASS\033[0m, \033[1;31m%d FAIL\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
