#!/usr/bin/env bash
# ============================================================================
# Perf orchestrator — runs qa/perf.sh end-to-end against BOTH backends with one
# command, the way qa/run.sh orchestrates the pass/fail suites (but this one
# MEASURES, it does not verdict, so it is separate from run.sh).
#
# Per backend it: builds the dual-engine binary once, registers that backend's
# Debezium connector (idempotent), boots the server (APP_PROFILE=dev), waits for
# :8080, runs qa/perf.sh, then stops the server and frees the port before the
# next backend. Postgres writes a fresh perf-report.md; MySQL appends its
# section, so you get PG vs MySQL side by side.
#
# Usage:
#   bash qa/perf-all.sh                          # 500/s x 30s, both backends
#   PERF_RATE=1000 PERF_DURATION=60 bash qa/perf-all.sh
#   BACKENDS="postgres" bash qa/perf-all.sh      # a single backend
#
# Prereqs: docker compose up (all containers healthy) and vegeta installed
# (go install github.com/tsenart/vegeta/v12@latest). Everything else is handled.
#
# Tunables pass straight through to qa/perf.sh (PERF_WARMUP, PERF_SEED,
# PERF_MAX_WORKERS, PERF_CDC_TIMEOUT, …); PERF_RATE/PERF_DURATION default higher
# here (a real load run, not the smoke defaults).
# ============================================================================
set -u

QA_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$QA_DIR/.." && pwd)"       # example-users module root
cd "$ROOT"

BACKENDS="${BACKENDS:-postgres mysql}"
BIN="/tmp/omnicore-perf-srv"
LOGDIR="$(mktemp -d)"

# Real-load defaults (override on the command line). Exported so the qa/perf.sh
# child inherits them.
export PERF_RATE="${PERF_RATE:-500}"
export PERF_DURATION="${PERF_DURATION:-30}"
export PERF_SEED="${PERF_SEED:-1000}"   # more distinct read ids → less cache-hit skew
# Settle time between backends. Running them back-to-back lets the FIRST
# backend's async pipeline (outbox → Debezium → Kafka → SyncEngine → Mongo) keep
# churning the host's disk/CPU while the SECOND backend writes — which saturates
# I/O and contaminates the second measurement (and, with MySQL's unbounded pool,
# can snowball into 500s that do NOT occur on a quiet host). This drains it.
COOLDOWN="${PERF_COOLDOWN:-30}"

hr()  { printf '\n\033[1;35m%s\033[0m\n' "############################################################"; }
info(){ printf '\033[0;37m%s\033[0m\n' "$1"; }
die() { printf '\033[1;31mperf-all: %s\033[0m\n' "$1" >&2; exit 1; }

# ── Preflight ───────────────────────────────────────────────────────────────
command -v vegeta >/dev/null || [ -x "$(go env GOPATH)/bin/vegeta" ] || die "vegeta not found — go install github.com/tsenart/vegeta/v12@latest"
docker ps >/dev/null 2>&1 || die "docker not available"
docker ps --format '{{.Names}}' | grep -q omnicore-example-postgres || die "docker compose stack not up — run: docker compose -f devops/docker-compose.yml up -d"

SRV_PID=""
stop_server() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  pkill -f "$BIN" 2>/dev/null || true
  # Wait for :8080 to actually free before the next boot (avoids EADDRINUSE).
  local n=0
  while curl -sf -o /dev/null http://localhost:8080/users 2>/dev/null; do
    n=$((n+1)); [ "$n" -ge 40 ] && break; sleep 0.25
  done
  SRV_PID=""
}
trap 'stop_server; rm -rf "$LOGDIR"' EXIT

# ── Build once (dual engine) ────────────────────────────────────────────────
hr; info "Building dual-engine binary → $BIN"
go build -tags 'postgres mysql' -o "$BIN" ./bootstrap || die "build failed"

# ── Per-backend cycle ───────────────────────────────────────────────────────
first=1
for be in $BACKENDS; do
  case "$be" in postgres|mysql) ;; *) die "unknown backend '$be' (want postgres|mysql)";; esac
  hr; info "===== BACKEND=$be  —  ${PERF_RATE}/s x ${PERF_DURATION}s ====="

  if [ "$first" != 1 ]; then
    info "Cooldown ${COOLDOWN}s — draining the previous backend's CDC/Kafka/Mongo backlog so this run measures a quiet host…"
    sleep "$COOLDOWN"
  fi

  stop_server                              # free :8080 from any stale server
  export BACKEND="$be"
  # shellcheck disable=SC1091
  source qa/_backend.sh                     # env for boot + qa_* helpers

  info "Registering $be Debezium connector (idempotent)…"
  if [ "$be" = "mysql" ]; then
    ./devops/debezium/register-connector.sh mysql >/dev/null 2>&1 || info "  (connector register returned non-zero — continuing; may already exist)"
  else
    ./devops/debezium/register-connector.sh       >/dev/null 2>&1 || info "  (connector register returned non-zero — continuing; may already exist)"
  fi

  info "Booting server (APP_PROFILE=dev)…"
  APP_PROFILE=dev "$BIN" > "$LOGDIR/$be.log" 2>&1 &
  SRV_PID=$!
  if ! curl --retry-connrefused --retry 60 --retry-delay 1 -sf -o /dev/null http://localhost:8080/users; then
    info "---- last boot log ($be) ----"; tail -30 "$LOGDIR/$be.log"
    die "server for $be never became ready on :8080"
  fi
  info "Server ready."

  if [ "$first" = 1 ]; then
    PERF_FRESH=1 bash qa/perf.sh || die "perf.sh failed for $be"
    first=0
  else
    PERF_FRESH=0 bash qa/perf.sh || die "perf.sh failed for $be"
  fi

  stop_server
done

hr; info "ALL DONE — report: $ROOT/../perf-report.md"
