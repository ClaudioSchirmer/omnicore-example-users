#!/usr/bin/env bash
# qa/run.sh — the one-command QA matrix: every suite, both relational backends,
# one report.
#
#   ./qa/run.sh              # full matrix: all suites × postgres + mysql
#   ./qa/run.sh postgres     # one backend only
#   ./qa/run.sh mysql
#   SUITES="e2e employee" ./qa/run.sh   # subset (space-separated overrides)
#   ./qa/run.sh --keep-going            # do NOT stop at the first RED suite
#
# FAIL-FAST is the default: the matrix stops at the FIRST suite that goes RED
# (server stopped, remaining runs reported as "never ran", exit 1) so a broken
# run surfaces in seconds instead of after the whole matrix. Pass --keep-going
# (or KEEP_GOING=1) to run every scheduled suite regardless of failures — the
# old exhaustive behavior, useful to size the blast radius of a change.
#
# Prerequisites: the bench up (docker compose -f devops/docker-compose.yml up -d)
# and jq installed. Everything else is handled here: the dual-engine binary is
# built once; the Debezium connector for each backend is (re)registered — the
# register script itself waits for the outbox table, so a virgin volume works
# as long as the server boots first (this runner boots it first); the
# "running already" suites (e2e, employee, person, graphql, openapi, httpclient) run
# against a server this script starts and stops per backend; the self-managed
# suites (audit, cache, authz, schema_evolution, auth) get a free :8080.
#
# Report: written INCREMENTALLY (one row as each suite × backend finishes) to
# qa-report.md at the STACK ROOT (two levels above qa/), plus the same lines on
# the console. Each row carries the suite's own PASS/FAIL counts (parsed from
# its summary; exit code as fallback). A backend that aborts mid-way leaves an
# ABORT row, and the final verdict also goes red when fewer runs completed than
# were scheduled — a run can never look green by silently skipping suites.
# Exit code: 0 only when every scheduled run completed green.
#
# Logs: per-run temp dir, removed at the end when the verdict is ALL GREEN
# (kept on RED for diagnosis). A caller-provided QA_RUN_LOG_DIR is never
# auto-removed.
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
# The Gadget-mirror suites (lifecycle_hooks, filter_operators, view_options,
# status_mapping, httpclient_middleware, upstream_composition, integration_events)
# build their OWN `-tags '<engine> qa'` binary and boot microservice.qa.yaml —
# they exercise the qa-only Gadget mirror aggregate, invisible to the canonical
# binary the server suites use. config_validation/migrations/tracing are
# framework control-plane suites needing no mirror entity.
SERVER_SUITES="e2e employee person graphql openapi httpclient"
SELF_SUITES="audit cache authz schema_evolution config_validation migrations tracing status_mapping view_options httpclient_middleware lifecycle_hooks filter_operators upstream_composition integration_events auth"
ALL_SUITES="$SERVER_SUITES $SELF_SUITES"
SUITES="${SUITES:-$ALL_SUITES}"

SRV_BIN="${TMPDIR:-/tmp}/omnicore-example-users-qa-run-srv"
if [ -n "${QA_RUN_LOG_DIR:-}" ]; then
  LOG_DIR="$QA_RUN_LOG_DIR"; LOG_DIR_EPHEMERAL=0
else
  LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qa-run.XXXXXX")"; LOG_DIR_EPHEMERAL=1
fi
ROWS="$LOG_DIR/rows.tsv"        # machine-readable accounting: suite backend pass fail verdict secs
REPORT_MD="$STACK_ROOT/qa-report.md"
: > "$ROWS"

bold()  { printf '\033[1;37m%s\033[0m\n' "$1"; }
green() { printf '\033[1;32m%s\033[0m' "$1"; }
red()   { printf '\033[1;31m%s\033[0m' "$1"; }

# strip_ansi removes color codes so the summary regexes see plain text.
strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }

# ── Scheduled-run accounting ─────────────────────────────────────────────────
N_SUITES=0; for _s in $SUITES; do N_SUITES=$((N_SUITES+1)); done
N_BACKENDS=0; for _b in $BACKEND_LIST; do N_BACKENDS=$((N_BACKENDS+1)); done
EXPECTED_RUNS=$((N_SUITES * N_BACKENDS))

# ── Incremental markdown report at the stack root ────────────────────────────
report_init() {
  {
    echo "# QA Matrix Report"
    echo
    echo "- **Started:** $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- **Backends:** $BACKEND_LIST"
    echo "- **Suites:** $SUITES"
    echo "- **Scheduled runs:** $EXPECTED_RUNS"
    echo "- **Logs:** \`$LOG_DIR\`"
    echo
    echo "| Suite | Backend | Pass | Fail | Verdict | Time |"
    echo "|---|---|---:|---:|:---:|---:|"
  } > "$REPORT_MD"
}

report_row() { # report_row <suite> <backend> <pass> <fail> <verdict-word> <secs>
  local mark
  case "$5" in OK) mark="✅ OK" ;; *) mark="❌ $5" ;; esac
  printf '| %s | %s | %s | %s | %s | %ss |\n' "$1" "$2" "$3" "$4" "$mark" "$6" >> "$REPORT_MD"
}

report_final() { # report_final <verdict-line> <elapsed>
  {
    echo
    echo "**$1** — ${2}s total."
    echo
    echo "_Finished: $(date '+%Y-%m-%d %H:%M:%S')_"
  } >> "$REPORT_MD"
}

# summarize <log> <exit-code> → "passed failed" using the suite's own summary
# line; falls back to the exit code when no summary is recognized.
summarize() {
  local log="$1" rc="$2" plain line
  plain=$(strip_ansi < "$log")
  if line=$(grep -oE 'PASS=[0-9]+ +FAIL=[0-9]+' <<<"$plain" | tail -1) && [ -n "$line" ]; then
    local p f
    p=$(grep -oE 'PASS=[0-9]+' <<<"$line" | cut -d= -f2)
    f=$(grep -oE 'FAIL=[0-9]+' <<<"$line" | cut -d= -f2)
    echo "$p $f"
    return
  fi
  if line=$(grep -oE '[0-9]+ passed, [0-9]+ failed' <<<"$plain" | tail -1) && [ -n "$line" ]; then
    echo "$(cut -d' ' -f1 <<<"$line") $(cut -d' ' -f3 <<<"$line")"
    return
  fi
  if line=$(grep -oE '[0-9]+ PASS, [0-9]+ FAIL' <<<"$plain" | tail -1) && [ -n "$line" ]; then
    echo "$(cut -d' ' -f1 <<<"$line") $(awk '{print $3}' <<<"$line")"
    return
  fi
  # openapi prints "PASS: N" + "All N cases passed" (failures change the exit code)
  if line=$(grep -oE 'PASS: [0-9]+' <<<"$plain" | tail -1) && [ -n "$line" ]; then
    if [ "$rc" = "0" ]; then echo "$(cut -d' ' -f2 <<<"$line") 0"; else echo "$(cut -d' ' -f2 <<<"$line") ?"; fi
    return
  fi
  if [ "$rc" = "0" ]; then echo "? 0"; else echo "? ?"; fi
}

record() { # record <suite> <backend> <log> <rc> <secs> — returns 1 on a RED run
  local suite="$1" backend="$2" log="$3" rc="$4" secs="$5" counts p f word verdict
  counts=$(summarize "$log" "$rc")
  p=${counts%% *}; f=${counts##* }
  if [ "$f" = "0" ] && [ "$rc" = "0" ]; then
    word="OK";  verdict=$(green "OK ")
  else
    word="RED"; verdict=$(red "RED")
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$suite" "$backend" "$p" "$f" "$word" "$secs" >> "$ROWS"
  report_row "$suite" "$backend" "$p" "$f" "$word" "$secs"
  printf '%-18s %-9s %6s pass %5s fail   %s  %4ss  %s\n' \
    "$suite" "$backend" "$p" "$f" "$verdict" "$secs" "$log"
  [ "$word" = "OK" ]
}

# fail_fast <suite> <backend> — under the fail-fast default, mark the sentinel
# and tell the caller to stop; under --keep-going, a no-op. The final verdict
# already reports the un-run suites ("N never ran") and exits 1.
fail_fast() {
  [ "$KEEP_GOING" = "1" ] && return 1
  touch "$LOG_DIR/failfast"
  printf '%s fail-fast: %s (%s) went RED — stopping here (pass --keep-going to run everything)\n' \
    "$(red "✗")" "$1" "$2"
  return 0
}

# abort_backend leaves a visible RED row when a backend dies before its suites
# could run (e.g. the server never became healthy) — nothing disappears
# silently from the report.
abort_backend() { # abort_backend <backend> <reason>
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "(abort)" "$1" "-" "-" "ABORT" "-" >> "$ROWS"
  report_row "(abort: $2)" "$1" "-" "-" "ABORT" "-"
  printf '%-18s %-9s %6s pass %5s fail   %s  %4ss  %s\n' \
    "(abort)" "$1" "-" "-" "$(red "RED")" "-" "$2"
}

wait_health() {
  local deadline=$(( $(date +%s) + 90 ))
  until curl -sf http://localhost:8080/health >/dev/null 2>&1; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 1
  done
}

port_free() {
  local deadline=$(( $(date +%s) + 30 ))
  while lsof -ti :8080 >/dev/null 2>&1; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 1
  done
}

# wait_connector_running blocks until the backend's Debezium connector AND its
# task(s) report RUNNING. register-connector.sh updates an existing connector
# via PUT /config, which restarts the task — returning before it is back to
# RUNNING makes the first CDC-dependent suite race a dead pipeline and flake.
wait_connector_running() { # wait_connector_running <postgres|mysql>
  local cfg name deadline
  case "$1" in
    postgres) cfg="devops/debezium/users-outbox-connector.json" ;;
    mysql)    cfg="devops/debezium/users-outbox-connector-mysql.json" ;;
  esac
  name=$(jq -r '.name' "$cfg")
  deadline=$(( $(date +%s) + 90 ))
  while :; do
    if curl -sf "http://localhost:8083/connectors/$name/status" 2>/dev/null \
        | jq -e '(.connector.state == "RUNNING") and ((.tasks | length) > 0) and (([.tasks[].state] | unique) == ["RUNNING"])' >/dev/null 2>&1; then
      return 0
    fi
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 1
  done
}

bold "qa/run.sh — suites: $SUITES"
bold "backends: $BACKEND_LIST   logs: $LOG_DIR"
bold "report:   $REPORT_MD"

# ── Preflight ────────────────────────────────────────────────────────────────
command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 2; }
docker compose -f devops/docker-compose.yml ps --format '{{.Name}}' 2>/dev/null | grep -q postgres \
  || { echo "bench is not up — run: docker compose -f devops/docker-compose.yml up -d" >&2; exit 2; }
if grep -qE 'auth|authz' <<<"$SUITES"; then
  bold "waiting for Keycloak (auth/authz suites requested) ..."
  ./devops/keycloak/wait-ready.sh >/dev/null 2>&1 || true
fi

report_init

bold "building the dual-engine binary once ..."
go build -tags 'postgres mysql qa' -o "$SRV_BIN" ./bootstrap || { echo "build failed" >&2; exit 1; }

overall_start=$(date +%s)
for B in $BACKEND_LIST; do
  bold ""
  bold "════════ backend: $B ════════"
  (
    export BACKEND="$B"
    # shellcheck source=qa/_backend.sh
    source qa/_backend.sh

    pkill -f "$SRV_BIN" 2>/dev/null; sleep 1

    run_server_suites=""
    run_self_suites=""
    for s in $SUITES; do
      if grep -qw "$s" <<<"$SERVER_SUITES"; then run_server_suites="$run_server_suites $s"; fi
      if grep -qw "$s" <<<"$SELF_SUITES";   then run_self_suites="$run_self_suites $s"; fi
    done

    if [ -n "$run_server_suites" ]; then
      APP_PROFILE=dev "$SRV_BIN" > "$LOG_DIR/server-$B.log" 2>&1 &
      SRV_PID=$!
      wait_health || {
        echo "server never became healthy for $B (see $LOG_DIR/server-$B.log)" >&2
        kill "$SRV_PID" 2>/dev/null
        abort_backend "$B" "server never became healthy"
        exit 1
      }
      # The register script waits for the outbox table itself; the server boot
      # above guarantees it exists even on a virgin volume.
      ./devops/debezium/register-connector.sh "$B" > "$LOG_DIR/connector-$B.log" 2>&1 \
        || echo "WARNING: connector registration failed for $B (see $LOG_DIR/connector-$B.log)" >&2
      wait_connector_running "$B" \
        || echo "WARNING: connector for $B not RUNNING after 90s — CDC suites may flake" >&2
      sleep 3
      for s in $run_server_suites; do
        t0=$(date +%s)
        ./qa/$s.sh > "$LOG_DIR/$s-$B.log" 2>&1
        rc=$?
        if ! record "$s" "$B" "$LOG_DIR/$s-$B.log" "$rc" "$(( $(date +%s) - t0 ))"; then
          if fail_fast "$s" "$B"; then
            kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null
            exit 1
          fi
        fi
      done
      kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null
      port_free || {
        echo ":8080 still busy after stopping the server" >&2
        abort_backend "$B" ":8080 still busy after stopping the server"
        exit 1
      }
    fi

    for s in $run_self_suites; do
      t0=$(date +%s)
      ./qa/$s.sh > "$LOG_DIR/$s-$B.log" 2>&1
      rc=$?
      if ! record "$s" "$B" "$LOG_DIR/$s-$B.log" "$rc" "$(( $(date +%s) - t0 ))"; then
        fail_fast "$s" "$B" && exit 1
      fi
      port_free >/dev/null 2>&1 || true
    done
  ) || true   # the abort row already carries the failure into the accounting
  # Fail-fast sentinel: a suite went RED inside the subshell — stop the whole
  # matrix (remaining backends included) instead of grinding on.
  [ -f "$LOG_DIR/failfast" ] && break
done

# The per-backend subshell appended each row to $ROWS; totals come from there
# (subshell counters do not propagate). Completed = rows that are real suite
# runs; red = rows whose verdict is not OK; missing = scheduled but never run.
COMPLETED_RUNS=$(grep -cv $'\tABORT\t' "$ROWS" 2>/dev/null); COMPLETED_RUNS=${COMPLETED_RUNS:-0}
RED_RUNS=$(awk -F'\t' '$5 != "OK"' "$ROWS" | grep -c . 2>/dev/null); RED_RUNS=${RED_RUNS:-0}
MISSING_RUNS=$((EXPECTED_RUNS - COMPLETED_RUNS))

bold ""
bold "════════════════ QA MATRIX REPORT ════════════════"
awk -F'\t' '{printf "  %-18s %-9s %6s pass %5s fail   %-5s %4ss\n", $1, $2, $3, $4, $5, $6}' "$ROWS"
bold "═══════════════════════════════════════════════════"
elapsed=$(( $(date +%s) - overall_start ))
if [ "$RED_RUNS" = "0" ] && [ "$MISSING_RUNS" = "0" ] && [ "$COMPLETED_RUNS" != "0" ]; then
  logs_note="$LOG_DIR"
  if [ "$LOG_DIR_EPHEMERAL" = "1" ]; then
    rm -rf "$LOG_DIR"
    logs_note="removed (all green)"
  fi
  report_final "✅ ALL GREEN — $COMPLETED_RUNS/$EXPECTED_RUNS runs. Logs $logs_note." "$elapsed"
  printf '%s — %s/%s runs, %ss, report: %s, logs: %s\n' \
    "$(green "ALL GREEN")" "$COMPLETED_RUNS" "$EXPECTED_RUNS" "$elapsed" "$REPORT_MD" "$logs_note"
  exit 0
else
  detail="$RED_RUNS red"
  [ "$MISSING_RUNS" != "0" ] && detail="$detail, $MISSING_RUNS never ran"
  [ -f "$LOG_DIR/failfast" ] && detail="$detail (fail-fast — pass --keep-going for the full sweep)"
  report_final "❌ RED — $detail of $EXPECTED_RUNS scheduled runs. Logs kept: \`$LOG_DIR\`" "$elapsed"
  printf '%s — %s of %s scheduled runs, %ss, report: %s, logs: %s\n' \
    "$(red "RED")" "$detail" "$EXPECTED_RUNS" "$elapsed" "$REPORT_MD" "$LOG_DIR"
  exit 1
fi
