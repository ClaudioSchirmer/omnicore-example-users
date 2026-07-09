#!/usr/bin/env bash
# qa/run.sh — the one-command QA matrix: every suite, BOTH transport lanes, run
# in PARALLEL, one report.
#
#   ./qa/run.sh              # both lanes in parallel (the default)
#   ./qa/run.sh postgres     # one lane only (Postgres + Kafka)
#   ./qa/run.sh mysql        #                (MySQL + NATS)
#   SUITES="e2e employee" ./qa/run.sh   # subset (space-separated overrides)
#   ./qa/run.sh --keep-going            # do NOT stop at the first RED suite
#
# The two lanes exercise BOTH legs of the transport seam every run:
#   • Lane A — Postgres + Kafka + Mongo, relay Debezium CONNECT (:8081 / gRPC :9091)
#   • Lane B — MySQL   + NATS  + Mongo, relay Debezium SERVER  (:8082 / gRPC :9092)
# Each lane runs on its OWN app ports, binary, relay and Redis, and its OWN Mongo
# DB (users_views / users_views_mysql), so they never collide — the whole suite
# list runs on each lane concurrently. Wall-clock ≈ the slower lane, not the sum.
#
# FAIL-FAST is the default: the FIRST suite that goes RED (on either lane) trips a
# shared sentinel and BOTH lanes stop at their next suite boundary (remaining runs
# reported "never ran", exit 1). Pass --keep-going (or KEEP_GOING=1) to run every
# scheduled suite regardless — the exhaustive sweep for sizing a change.
#
# Prerequisites: the QA bench up (docker compose -f devops/docker-compose.yml up -d)
# and jq installed. Everything else is handled here: each lane builds its own
# single-transport binary; the lane's relay is (re)started and proven streaming;
# the "running already" suites run against a per-lane server this script starts
# and stops; the self-managed suites get their lane's free port.
#
# Report: qa-report.md at the STACK ROOT (two levels above qa/), one section per
# lane, written when the run completes. Exit code: 0 only when every scheduled run
# completed green. Logs: per-run temp dir, removed on ALL GREEN, kept on RED.
set -u

cd "$(dirname "$0")/.."
STACK_ROOT="$(cd ../ && pwd)"

BACKENDS="all"
KEEP_GOING="${KEEP_GOING:-0}"
for arg in "$@"; do
  case "$arg" in
    all|postgres|mysql) BACKENDS="$arg" ;;
    --keep-going|-k)    KEEP_GOING=1 ;;
    *) echo "usage: qa/run.sh [all|postgres|mysql] [--keep-going]" >&2; exit 2 ;;
  esac
done
case "$BACKENDS" in
  all)      BACKEND_LIST="postgres mysql" ;;
  postgres) BACKEND_LIST="postgres" ;;
  mysql)    BACKEND_LIST="mysql" ;;
esac

# Server-dependent suites run first (server up), self-managed after (port free).
# auth is last: it is the slowest (~5 min of validator-mode + cache-TTL waits).
SERVER_SUITES="e2e employee person graphql openapi httpclient"
SELF_SUITES="audit cache authz schema_evolution config_validation migrations tracing status_mapping view_options httpclient_middleware lifecycle_hooks filter_operators upstream_composition composed_view external_embed integration_events auth grpc grpcclient grpc_security"
ALL_SUITES="$SERVER_SUITES $SELF_SUITES"
SUITES="${SUITES:-$ALL_SUITES}"

# Suites that MUST run alone: schema_evolution mutates the SHARED source tree
# (internal/infra/views.go) + a shared backup path and rebuilds, so it cannot run
# concurrently with any other build (the other lane would compile the patched
# source). They run SERIALLY after the parallel matrix, one lane at a time.
SERIAL_SUITES="schema_evolution"

if [ -n "${QA_RUN_LOG_DIR:-}" ]; then
  LOG_DIR="$QA_RUN_LOG_DIR"; LOG_DIR_EPHEMERAL=0
else
  LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qa-run.XXXXXX")"; LOG_DIR_EPHEMERAL=1
fi
REPORT_MD="$STACK_ROOT/qa-report.md"

bold()  { printf '\033[1;37m%s\033[0m\n' "$1"; }
green() { printf '\033[1;32m%s\033[0m' "$1"; }
red()   { printf '\033[1;31m%s\033[0m' "$1"; }
strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }

# ── Scheduled-run accounting ─────────────────────────────────────────────────
N_SUITES=0; for _s in $SUITES; do N_SUITES=$((N_SUITES+1)); done
N_BACKENDS=0; for _b in $BACKEND_LIST; do N_BACKENDS=$((N_BACKENDS+1)); done
EXPECTED_RUNS=$((N_SUITES * N_BACKENDS))

# summarize <log> <exit-code> → "passed failed" from the suite's own summary
# line, falling back to the exit code when no summary is recognized.
summarize() {
  local log="$1" rc="$2" plain line
  plain=$(strip_ansi < "$log")
  if line=$(grep -oE 'PASS=[0-9]+ +FAIL=[0-9]+' <<<"$plain" | tail -1) && [ -n "$line" ]; then
    echo "$(grep -oE 'PASS=[0-9]+' <<<"$line" | cut -d= -f2) $(grep -oE 'FAIL=[0-9]+' <<<"$line" | cut -d= -f2)"; return
  fi
  if line=$(grep -oE '[0-9]+ passed, [0-9]+ failed' <<<"$plain" | tail -1) && [ -n "$line" ]; then
    echo "$(cut -d' ' -f1 <<<"$line") $(cut -d' ' -f3 <<<"$line")"; return
  fi
  if line=$(grep -oE '[0-9]+ PASS, [0-9]+ FAIL' <<<"$plain" | tail -1) && [ -n "$line" ]; then
    echo "$(cut -d' ' -f1 <<<"$line") $(awk '{print $3}' <<<"$line")"; return
  fi
  if line=$(grep -oE 'PASS: [0-9]+' <<<"$plain" | tail -1) && [ -n "$line" ]; then
    if [ "$rc" = "0" ]; then echo "$(cut -d' ' -f2 <<<"$line") 0"; else echo "$(cut -d' ' -f2 <<<"$line") ?"; fi; return
  fi
  if [ "$rc" = "0" ]; then echo "? 0"; else echo "? ?"; fi
}

# record <suite> <backend> <log> <rc> <secs> — writes a machine row to the lane's
# $LANE_ROWS + a markdown row to the lane's $LANE_FRAG + a console line. Returns 1
# on a RED run. (Each lane has its OWN files → no concurrent-write races.)
record() {
  local suite="$1" backend="$2" log="$3" rc="$4" secs="$5" counts p f word verdict mark
  counts=$(summarize "$log" "$rc"); p=${counts%% *}; f=${counts##* }
  if [ "$f" = "0" ] && [ "$rc" = "0" ]; then word="OK"; verdict=$(green "OK "); mark="✅ OK"
  else word="RED"; verdict=$(red "RED"); mark="❌ RED"; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$suite" "$backend" "$p" "$f" "$word" "$secs" >> "$LANE_ROWS"
  printf '| %s | %s | %s | %s | %s | %ss |\n' "$suite" "$backend" "$p" "$f" "$mark" "$secs" >> "$LANE_FRAG"
  printf '%-18s %-9s %6s pass %5s fail   %s  %4ss  %s\n' "$suite" "$backend" "$p" "$f" "$verdict" "$secs" "$log"
  [ "$word" = "OK" ]
}

abort_lane() { # abort_lane <backend> <reason>
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "(abort)" "$1" "-" "-" "ABORT" "-" >> "$LANE_ROWS"
  printf '| (abort: %s) | %s | - | - | ❌ ABORT | - |\n' "$2" "$1" >> "$LANE_FRAG"
  printf '%-18s %-9s %6s pass %5s fail   %s  %4ss  %s\n' "(abort)" "$1" "-" "-" "$(red "RED")" "-" "$2"
}

# fail_fast <suite> <backend> — trip the shared sentinel (unless --keep-going) so
# BOTH lanes stop at their next suite boundary.
fail_fast() {
  [ "$KEEP_GOING" = "1" ] && return 1
  touch "$LOG_DIR/failfast"
  printf '%s fail-fast: %s (%s) went RED — stopping both lanes (pass --keep-going for the full sweep)\n' \
    "$(red "✗")" "$1" "$2"
  return 0
}
stop_requested() { [ -f "$LOG_DIR/failfast" ]; }

# ── Lane-scoped pipeline helpers (read the lane env sourced from _backend.sh) ──
wait_health() {
  local deadline=$(( $(date +%s) + 90 ))
  until curl -sf "$BASE/health" >/dev/null 2>&1; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 1
  done
}
port_free() {
  local deadline=$(( $(date +%s) + 30 ))
  while lsof -ti :"${HTTP_PORT:-8080}" >/dev/null 2>&1; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 1
  done
}
# relay_setup (re)starts the lane's CDC relay and confirms it is streaming.
# register-connector.sh dispatches by dialect: Connect REST (postgres) or a
# Debezium Server recreate (mysql). Both already block until streaming/RUNNING.
relay_setup() { # relay_setup <backend> <logfile>
  ./devops/debezium/register-connector.sh "$1" > "$2" 2>&1
}
# cdc_warmup proves the WHOLE pipeline is hot before the first CDC-dependent
# suite asserts under its own deadlines. Non-fatal: a cold pipeline downgrades to
# a warning and the suites' own waits still apply.
cdc_warmup() {
  local doc id deadline c t0
  doc="9$(date +%s)"; t0=$(date +%s)
  id=$(curl -sS -X POST "$BASE/users" -H "Content-Type: application/json" \
    --data "{\"name\":\"QA Warmup Sentinel\",\"email\":\"warmup-$doc@qa.local\",\"phone\":\"14155550100\",\"document\":\"$doc\",\"userName\":\"warmup$doc\",\"emailNotification\":false,\"smsNotification\":false}" \
    | jq -r '.data.id // .data // empty' 2>/dev/null)
  deadline=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    c=$(docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet \
      --eval "db.users.countDocuments({document:'$doc'})" 2>/dev/null | tail -1 | tr -d ' ')
    [ "${c:-0}" -ge 1 ] 2>/dev/null && break
    sleep 1
  done
  if [ "${c:-0}" -ge 1 ] 2>/dev/null; then
    bold "[$BACKEND] cdc warmup: pipeline hot in $(( $(date +%s) - t0 ))s"
  else
    echo "[$BACKEND] WARNING: cdc warmup sentinel never landed in Mongo after 120s — CDC suites may flake" >&2
  fi
  [ -n "$id" ] && curl -sS -o /dev/null -X DELETE "$BASE/users/$id" 2>/dev/null || true
}

# ── One lane's full pipeline (runs as a background job) ───────────────────────
run_lane() {
  local B="$1"
  export BACKEND="$B"
  # shellcheck source=qa/_backend.sh
  source qa/_backend.sh
  LANE_ROWS="$LOG_DIR/rows-$B.tsv"; LANE_FRAG="$LOG_DIR/frag-$B.md"
  : > "$LANE_ROWS"; : > "$LANE_FRAG"
  local SRV_BIN="$LOG_DIR/srv-$B"

  bold "[$B] building the '$QA_BUILD_TAGS qa' binary ..."
  if ! go build -tags "$QA_BUILD_TAGS qa" -o "$SRV_BIN" ./bootstrap > "$LOG_DIR/build-$B.log" 2>&1; then
    abort_lane "$B" "build failed"; return 1
  fi
  pkill -f "$SRV_BIN" 2>/dev/null; sleep 1

  # Preflight: drop the qa-only view collections (gadget mirror + embed-showcase
  # views + upstream_items) from THIS lane's view DB so a prd/authz-profile boot's
  # DB-per-service registry guard never trips over an orphan from a prior crash.
  # Also drop the three core view collections alongside their registry rows below,
  # so the framework re-initializes them at v1 from a CONSISTENT clean state. (Row
  # without collection → downgrade guard; collection without row → trust-on-first-
  # use guard. Clearing BOTH avoids either.)
  docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval \
    "db.getCollectionNames().filter(n => /^(gadget|upstream_|qa_)/.test(n) || ['users','employees','persons'].includes(n)).forEach(n => db.getCollection(n).drop())" \
    >/dev/null 2>&1 || true
  # Drop the schema-evolution-managed registry rows so a leftover version=2 from a
  # prior run's schema_evolution can't trip the downgrade guard when the v1 qa
  # binary boots here (paired with the collection drop above → fresh v1 on boot).
  qa_db_exec "DELETE FROM omnicore_mongo_views WHERE view_name IN ('users','employees','persons');" 2>/dev/null || true

  local run_server_suites="" run_self_suites=""
  for s in $SUITES; do
    grep -qw "$s" <<<"$SERIAL_SUITES" && continue   # serial suites run after the parallel matrix
    grep -qw "$s" <<<"$SERVER_SUITES" && run_server_suites="$run_server_suites $s"
    grep -qw "$s" <<<"$SELF_SUITES"   && run_self_suites="$run_self_suites $s"
  done

  if [ -n "$run_server_suites" ]; then
    APP_PROFILE=dev "$SRV_BIN" > "$LOG_DIR/server-$B.log" 2>&1 &
    local SRV_PID=$!
    if ! wait_health; then
      echo "[$B] server never became healthy (see $LOG_DIR/server-$B.log)" >&2
      kill "$SRV_PID" 2>/dev/null; abort_lane "$B" "server never became healthy"; return 1
    fi
    relay_setup "$B" "$LOG_DIR/connector-$B.log" \
      || echo "[$B] WARNING: relay (re)start failed (see $LOG_DIR/connector-$B.log)" >&2
    cdc_warmup
    for s in $run_server_suites; do
      stop_requested && break
      local t0=$(date +%s)
      ./qa/$s.sh > "$LOG_DIR/$s-$B.log" 2>&1; local rc=$?
      if ! record "$s" "$B" "$LOG_DIR/$s-$B.log" "$rc" "$(( $(date +%s) - t0 ))"; then
        fail_fast "$s" "$B" && { kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; return 1; }
      fi
    done
    kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null
    port_free || { abort_lane "$B" ":${HTTP_PORT} still busy after stopping the server"; return 1; }
  fi

  for s in $run_self_suites; do
    stop_requested && break
    local t0=$(date +%s)
    ./qa/$s.sh > "$LOG_DIR/$s-$B.log" 2>&1; local rc=$?
    if ! record "$s" "$B" "$LOG_DIR/$s-$B.log" "$rc" "$(( $(date +%s) - t0 ))"; then
      fail_fast "$s" "$B" && return 1
    fi
    port_free >/dev/null 2>&1 || true
  done
}

# ── Preflight ────────────────────────────────────────────────────────────────
command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 2; }
docker compose -f devops/docker-compose.yml ps --format '{{.Name}}' 2>/dev/null | grep -q omnicore-qa-postgres \
  || { echo "QA bench is not up — run: docker compose -f devops/docker-compose.yml up -d" >&2; exit 2; }
if grep -qE 'auth|authz' <<<"$SUITES"; then
  bold "waiting for Keycloak (auth/authz suites requested) ..."
  ./devops/keycloak/wait-ready.sh >/dev/null 2>&1 || true
fi

bold "qa/run.sh — suites: $SUITES"
bold "lanes: $BACKEND_LIST (parallel)   logs: $LOG_DIR"
bold "report: $REPORT_MD"

# ── Launch the lanes in parallel ─────────────────────────────────────────────
overall_start=$(date +%s)
LANE_PIDS=""
for B in $BACKEND_LIST; do
  run_lane "$B" &
  LANE_PIDS="$LANE_PIDS $!"
done
for pid in $LANE_PIDS; do wait "$pid"; done

# ── Serial phase: the source-mutating suites, one lane at a time ─────────────
# schema_evolution patches internal/infra/views.go and rebuilds, so it runs only
# now that every parallel build has finished — and postgres then mysql, never
# together, since they share the source tree + backup path.
serial_requested=""
for s in $SUITES; do grep -qw "$s" <<<"$SERIAL_SUITES" && serial_requested="$serial_requested $s"; done
if [ -n "$serial_requested" ] && ! stop_requested; then
  bold ""
  bold "──────── serial phase (source-mutating suites):$serial_requested ────────"
  for B in $BACKEND_LIST; do
    ( export BACKEND="$B"
      # shellcheck source=qa/_backend.sh
      source qa/_backend.sh
      LANE_ROWS="$LOG_DIR/rows-$B.tsv"; LANE_FRAG="$LOG_DIR/frag-$B.md"
      for s in $serial_requested; do
        stop_requested && break
        t0=$(date +%s)
        ./qa/$s.sh > "$LOG_DIR/$s-$B.log" 2>&1; rc=$?
        record "$s" "$B" "$LOG_DIR/$s-$B.log" "$rc" "$(( $(date +%s) - t0 ))" || fail_fast "$s" "$B"
      done
    )
  done
fi

elapsed=$(( $(date +%s) - overall_start ))

# ── Merge the per-lane fragments into the report ─────────────────────────────
{
  echo "# QA Matrix Report"
  echo
  echo "- **Finished:** $(date '+%Y-%m-%d %H:%M:%S')"
  echo "- **Lanes:** $BACKEND_LIST (parallel)"
  echo "- **Suites:** $SUITES"
  echo "- **Scheduled runs:** $EXPECTED_RUNS"
  for B in $BACKEND_LIST; do
    case "$B" in
      postgres) echo; echo "## Lane A — Postgres + Kafka (Debezium Connect)" ;;
      mysql)    echo; echo "## Lane B — MySQL + NATS (Debezium Server)" ;;
    esac
    echo
    echo "| Suite | Backend | Pass | Fail | Verdict | Time |"
    echo "|---|---|---:|---:|:---:|---:|"
    [ -f "$LOG_DIR/frag-$B.md" ] && cat "$LOG_DIR/frag-$B.md"
  done
} > "$REPORT_MD"

# ── Accounting from the per-lane rows ────────────────────────────────────────
cat "$LOG_DIR"/rows-*.tsv > "$LOG_DIR/rows.tsv" 2>/dev/null || : > "$LOG_DIR/rows.tsv"
COMPLETED_RUNS=$(grep -cv $'\tABORT\t' "$LOG_DIR/rows.tsv" 2>/dev/null); COMPLETED_RUNS=${COMPLETED_RUNS:-0}
RED_RUNS=$(awk -F'\t' '$5 != "OK"' "$LOG_DIR/rows.tsv" | grep -c . 2>/dev/null); RED_RUNS=${RED_RUNS:-0}
MISSING_RUNS=$((EXPECTED_RUNS - COMPLETED_RUNS))

bold ""
bold "════════════════ QA MATRIX REPORT ════════════════"
awk -F'\t' '{printf "  %-18s %-9s %6s pass %5s fail   %-5s %4ss\n", $1, $2, $3, $4, $5, $6}' "$LOG_DIR/rows.tsv"
bold "═══════════════════════════════════════════════════"

if [ "$RED_RUNS" = "0" ] && [ "$MISSING_RUNS" = "0" ] && [ "$COMPLETED_RUNS" != "0" ]; then
  logs_note="$LOG_DIR"
  { echo; echo "**✅ ALL GREEN — $COMPLETED_RUNS/$EXPECTED_RUNS runs — ${elapsed}s total.**"; } >> "$REPORT_MD"
  if [ "$LOG_DIR_EPHEMERAL" = "1" ]; then rm -rf "$LOG_DIR"; logs_note="removed (all green)"; fi
  printf '%s — %s/%s runs, %ss, report: %s, logs: %s\n' \
    "$(green "ALL GREEN")" "$COMPLETED_RUNS" "$EXPECTED_RUNS" "$elapsed" "$REPORT_MD" "$logs_note"
  exit 0
else
  detail="$RED_RUNS red"
  [ "$MISSING_RUNS" != "0" ] && detail="$detail, $MISSING_RUNS never ran"
  [ -f "$LOG_DIR/failfast" ] && detail="$detail (fail-fast — pass --keep-going for the full sweep)"
  { echo; echo "**❌ RED — $detail of $EXPECTED_RUNS scheduled runs — ${elapsed}s total. Logs: \`$LOG_DIR\`**"; } >> "$REPORT_MD"
  printf '%s — %s of %s scheduled runs, %ss, report: %s, logs: %s\n' \
    "$(red "RED")" "$detail" "$EXPECTED_RUNS" "$elapsed" "$REPORT_MD" "$LOG_DIR"
  exit 1
fi
