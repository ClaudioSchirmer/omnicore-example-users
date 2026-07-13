#!/usr/bin/env bash
# Boot-time configuration-rejection suite for omnicore-example-users.
#
# The framework validates the resolved config BEFORE it touches any infra, and
# aborts the boot with a specific diagnostic when the config is incoherent.
# Every "happy" QA suite proves the framework boots on a GOOD config; this one
# proves it REFUSES to boot on a bad one, with a legible message — the other
# half of the contract. Three guards, each exercised against a generated YAML
# override so the on-disk profiles are never mutated:
#
#   1. Missing mandatory field        → "missing required config: service"
#   2. auth.mode=disabled outside dev → "auth.mode=... is not allowed when APP_PROFILE"
#   3. cache.shared.store: memory     → "not allowed for the shared cache"
#
# Config validation runs at load (before DB/Kafka/Mongo), so each boot aborts
# in well under a second and needs no running infra.
#
# Run from anywhere:  bash qa/config_validation.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-config-validation-${BACKEND:-postgres}"
DEV_YAML="$REPO_ROOT/microservice.dev.yaml"

PASS=0; FAIL=0
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

kill_port() {
  local pids; pids=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true)
  [ -n "$pids" ] && { kill -9 $pids 2>/dev/null || true; sleep 1; }
}

# expect_boot_abort <name> <profile> <config_path> <expected_substring>
# Boots the binary and expects it to EXIT non-zero within a few seconds while
# printing the expected diagnostic. A server that becomes healthy instead is a
# failure (the guard did not fire).
expect_boot_abort() {
  local name="$1" profile="$2" cfg="$3" needle="$4"
  title "$name"
  kill_port "${HTTP_PORT:-8080}"
  local log; log=$(mktemp)
  ( cd "$REPO_ROOT" && APP_PROFILE="$profile" OMNICORE_CONFIG_PATH="$cfg" \
      exec "$SERVER_BIN" >"$log" 2>&1 ) &
  local pid=$!
  local exited=fail code=0 deadline=$(( $(date +%s) + 15 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid" 2>/dev/null; code=$?; exited=ok; break; fi
    sleep 0.2
  done
  if [ "$exited" != ok ]; then
    kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    bad "$name — server did NOT abort (still running after 15s)"; echo "--- log ---"; tail -n 20 "$log"
    rm -f "$log"; kill_port "${HTTP_PORT:-8080}"; return
  fi
  echo "exit code: $code"
  if [ "$code" -eq 0 ]; then
    bad "$name — process exited 0 (expected a non-zero boot abort)"; tail -n 20 "$log"; rm -f "$log"; return
  fi
  if grep -qF "$needle" "$log"; then
    ok "$name — aborted (code $code) with: \"$needle\""
  else
    bad "$name — aborted but message missing \"$needle\""; echo "--- log ---"; tail -n 20 "$log"
  fi
  rm -f "$log"
}

##############################################################################
sec "0. Build server binary"
##############################################################################
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
ok "binary built: $SERVER_BIN"

##############################################################################
sec "1. Missing mandatory field → boot abort"
##############################################################################
# Strip the top-level `service:` line — Config.Validate() collects every empty
# mandatory field and aborts naming them.
CFG_NO_SERVICE=$(mktemp "/tmp/qa-boot-no-service-${BACKEND}.XXXXXX.yaml")
grep -v '^service:' "$DEV_YAML" > "$CFG_NO_SERVICE"
expect_boot_abort "1.1 no service: → missing required config" \
  dev "$CFG_NO_SERVICE" "missing required config: service"
rm -f "$CFG_NO_SERVICE"

##############################################################################
sec "2. auth.mode=disabled outside the dev profile → boot abort"
##############################################################################
# dev.yaml carries auth.mode=disabled (fine under dev). Boot the SAME file under
# a non-dev profile name: the profile-aware guard rejects shipping without auth.
expect_boot_abort "2.1 auth.mode=disabled under APP_PROFILE=prod → rejected" \
  prod "$DEV_YAML" "is not allowed when APP_PROFILE"

##############################################################################
sec "3. cache.shared.store: memory → boot abort"
##############################################################################
# An in-process LRU cannot back a cross-service shared cache; the framework
# rejects the combination at boot. Append a cache block declaring it.
CFG_SHARED_MEM=$(mktemp "/tmp/qa-boot-shared-mem-${BACKEND}.XXXXXX.yaml")
cat "$DEV_YAML" > "$CFG_SHARED_MEM"
cat >> "$CFG_SHARED_MEM" <<'YAML'

cache:
  store: memory
  shared:
    store: memory
YAML
expect_boot_abort "3.1 cache.shared.store: memory → rejected" \
  dev "$CFG_SHARED_MEM" "not allowed for the shared cache"
rm -f "$CFG_SHARED_MEM"

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
kill_port "${HTTP_PORT:-8080}"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
