#!/usr/bin/env bash
# Relational-migration control-plane suite for omnicore-example-users.
#
# The framework runs numbered service migrations at boot, gated by
# migrations.autoRun, which is the SAME three-mode model as mongo.rebuild
# (true / check / false). schema_evolution.sh covers the Mongo side; this
# suite covers the RELATIONAL side, which had no autoRun-mode coverage:
#
#   - autoRun=check + pending  → boot ABORTS naming the pending version(s)
#   - autoRun=false            → boot SKIPS (pending stays unapplied)
#   - autoRun=true             → boot APPLIES the pending migration
#   - dirty state              → boot ABORTS; Force (dirty=false) recovers
#
# It never edits the on-disk 0002 migration: a throwaway version 0003 is
# synthesized into a TEMP dir (a copy of migrations/$BACKEND) and MIGRATIONS_DIR
# points the boot at it. The control table (omnicore_migrations) + the probe
# table are reset to the 0002 baseline on the way out.
#
# Dialect-driven via qa/_backend.sh (BACKEND=postgres|mysql). Self-managed
# server lifecycle. Needs docker compose up (DB) — no Kafka/Mongo assertions.
#
# Run from anywhere:  bash qa/migrations.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-migrations"
DEV_YAML="$REPO_ROOT/microservice.dev.yaml"
TMP_MIG_DIR="/tmp/omnicore-qa-migrations-$BACKEND"
PROBE_TABLE="qa_migration_probe"

PASS=0; FAIL=0
SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }

reset_baseline() {
  qa_db_exec "DROP TABLE IF EXISTS $PROBE_TABLE;"
  # Restore omnicore_migrations to the single 0002 baseline row.
  qa_db_exec "DELETE FROM omnicore_migrations;"
  qa_db_exec "INSERT INTO omnicore_migrations (version, dirty) VALUES (2, false);"
}
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port 8080
  reset_baseline
  rm -rf "$TMP_MIG_DIR"
}
trap cleanup EXIT INT TERM

mk_autorun_yaml() {  # <mode> → prints path to a dev.yaml copy with migrations.autoRun=<mode>
  local mode="$1" out; out=$(mktemp "/tmp/qa-mig-${mode}.XXXXXX.yaml")
  awk -v m="$mode" '
    /^migrations:/ { in_m=1; print; next }
    in_m && /^[^ \t]/ { in_m=0 }
    in_m && /^  autoRun:/ { print "  autoRun: " m; next }
    { print }
  ' "$DEV_YAML" > "$out"
  echo "$out"
}

# boot_healthy <yaml> <log> → boots, waits for /health, leaves it running (SERVER_PID set)
boot_healthy() {
  local yaml="$1" log="$2"; : > "$log"; kill_port 8080
  ( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$yaml" MIGRATIONS_DIR="$TMP_MIG_DIR" exec "$SERVER_BIN" >>"$log" 2>&1 ) &
  SERVER_PID=$!
  local deadline=$(( $(date +%s) + 30 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/health" && return 0; kill -0 "$SERVER_PID" 2>/dev/null || return 1; sleep 0.5; done
  return 1
}
stop_server() { if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""; fi; kill_port 8080; }

# boot_expect_abort <yaml> <log> → boots expecting a non-zero exit; sets LAST_CODE
boot_expect_abort() {
  local yaml="$1" log="$2"; : > "$log"; kill_port 8080
  ( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$yaml" MIGRATIONS_DIR="$TMP_MIG_DIR" exec "$SERVER_BIN" >>"$log" 2>&1 ) &
  local pid=$! deadline=$(( $(date +%s) + 20 )); LAST_CODE=-1
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid" 2>/dev/null; LAST_CODE=$?; SERVER_PID=""; return 0; fi
    sleep 0.3
  done
  kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; SERVER_PID=""; return 1
}
probe_exists() {  # prints "yes"/"no"
  local n
  if [ "$BACKEND" = "mysql" ]; then
    n=$(qa_db_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='users_db' AND table_name='$PROBE_TABLE';")
  else
    n=$(qa_db_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='$PROBE_TABLE';")
  fi
  [ "${n:-0}" -ge 1 ] 2>/dev/null && echo yes || echo no
}
db_version() { qa_db_query "SELECT version FROM omnicore_migrations ORDER BY version DESC LIMIT 1;" | tr -d ' '; }

##############################################################################
sec "0. Build + baseline + synthesize a pending version 0003"
##############################################################################
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port 8080
reset_baseline
V=$(db_version); [ "$V" = "2" ] && ok "baseline omnicore_migrations at version 2" || bad "baseline version=$V (want 2)"

rm -rf "$TMP_MIG_DIR"; mkdir -p "$TMP_MIG_DIR"
cp "$REPO_ROOT/migrations/$BACKEND/"*.sql "$TMP_MIG_DIR/"
if [ "$BACKEND" = "mysql" ]; then
  printf 'CREATE TABLE %s (id BINARY(16) NOT NULL, note VARCHAR(64) NOT NULL, PRIMARY KEY (id));\n' "$PROBE_TABLE" > "$TMP_MIG_DIR/0003_qa_probe.up.sql"
else
  printf 'CREATE TABLE %s (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), note VARCHAR(64) NOT NULL);\n' "$PROBE_TABLE" > "$TMP_MIG_DIR/0003_qa_probe.up.sql"
fi
printf 'DROP TABLE IF EXISTS %s;\n' "$PROBE_TABLE" > "$TMP_MIG_DIR/0003_qa_probe.down.sql"
ok "synthesized pending 0003_qa_probe in $TMP_MIG_DIR"

##############################################################################
sec "1. autoRun=check + pending 0003 → boot ABORTS"
##############################################################################
Y_CHECK=$(mk_autorun_yaml check); LOG=/tmp/qa-mig-check.log
if boot_expect_abort "$Y_CHECK" "$LOG"; then
  [ "$LAST_CODE" -ne 0 ] && ok "check-mode boot aborted (exit $LAST_CODE)" || bad "check-mode exited 0 (expected abort)"
  grep -qF "pending migration(s) detected" "$LOG" && ok "diagnostic: 'pending migration(s) detected'" || { bad "pending diagnostic missing"; tail -n 15 "$LOG"; }
  grep -qE "version 3|required: 3" "$LOG" && ok "diagnostic names version 3" || bad "diagnostic did not name version 3"
else
  bad "check-mode did not exit within 20s"
fi
[ "$(probe_exists)" = no ] && ok "check mode did NOT apply 0003 (probe absent)" || bad "check mode created the probe table"
[ "$(db_version)" = "2" ] && ok "DB still at version 2 after check" || bad "DB version advanced under check"
rm -f "$Y_CHECK"

##############################################################################
sec "2. autoRun=false → boot SKIPS (pending stays unapplied)"
##############################################################################
Y_FALSE=$(mk_autorun_yaml false); LOG=/tmp/qa-mig-false.log
if boot_healthy "$Y_FALSE" "$LOG"; then
  ok "false-mode server booted healthy"
  grep -qF "migrations skipped (autoRun=false)" "$LOG" && ok "log: 'migrations skipped (autoRun=false)'" || bad "skip log line missing"
  [ "$(probe_exists)" = no ] && ok "false mode did NOT apply 0003" || bad "false mode created the probe table"
  [ "$(db_version)" = "2" ] && ok "DB still at version 2 after false" || bad "DB version advanced under false"
else
  bad "false-mode server did not become healthy"; tail -n 15 "$LOG"
fi
stop_server; rm -f "$Y_FALSE"

##############################################################################
sec "3. autoRun=true → boot APPLIES 0003"
##############################################################################
Y_TRUE=$(mk_autorun_yaml true); LOG=/tmp/qa-mig-true.log
if boot_healthy "$Y_TRUE" "$LOG"; then
  ok "true-mode server booted healthy"
  grep -qF "migrations applied" "$LOG" && ok "log: 'migrations applied'" || bad "applied log line missing"
  [ "$(probe_exists)" = yes ] && ok "true mode APPLIED 0003 (probe table exists)" || bad "probe table missing after true"
  [ "$(db_version)" = "3" ] && ok "DB advanced to version 3" || bad "DB version=$(db_version) (want 3)"
else
  bad "true-mode server did not become healthy"; tail -n 15 "$LOG"
fi
stop_server; rm -f "$Y_TRUE"

##############################################################################
sec "4. Dirty state → boot ABORTS; Force recovers"
##############################################################################
title "4.1 Mark version 3 dirty, boot check → dirty abort"
qa_db_exec "UPDATE omnicore_migrations SET dirty = true WHERE version = 3;"
Y_CHECK2=$(mk_autorun_yaml check); LOG=/tmp/qa-mig-dirty.log
if boot_expect_abort "$Y_CHECK2" "$LOG"; then
  [ "$LAST_CODE" -ne 0 ] && ok "dirty boot aborted (exit $LAST_CODE)" || bad "dirty boot exited 0"
  grep -qF "dirty state" "$LOG" && ok "diagnostic: 'dirty state'" || { bad "dirty diagnostic missing"; tail -n 15 "$LOG"; }
else
  bad "dirty-mode boot did not exit within 20s"
fi

title "4.2 Force clean (dirty=false), boot check → healthy"
qa_db_exec "UPDATE omnicore_migrations SET dirty = false WHERE version = 3;"
LOG=/tmp/qa-mig-recovered.log
if boot_healthy "$Y_CHECK2" "$LOG"; then
  ok "recovered server booted healthy under check"
  grep -qF "migrations up to date" "$LOG" && ok "log: 'migrations up to date (check mode)'" || bad "up-to-date log line missing"
else
  bad "recovered server did not become healthy"; tail -n 15 "$LOG"
fi
stop_server; rm -f "$Y_CHECK2"

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
# cleanup trap resets omnicore_migrations to (2,false) + drops the probe table.
if [ "$FAIL" -gt 0 ]; then exit 1; fi
