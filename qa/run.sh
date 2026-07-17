#!/usr/bin/env bash
# qa/run.sh — the one-command QA matrix: every suite, BOTH transport lanes, run
# in PARALLEL, one report.
#
#   ./qa/run.sh              # every available lane, in waves (the default)
#   ./qa/run.sh postgres     # one lane only (Postgres + Kafka)
#   ./qa/run.sh mysql        #                (MySQL + NATS)
#   SUITES="e2e employee" ./qa/run.sh   # subset (space-separated overrides)
#   ./qa/run.sh --keep-going            # do NOT stop at the first RED suite
#   QA_MAX_PARALLEL_LANES=4 ./qa/run.sh # full parallelism (needs a roomier Docker VM)
#
# The lanes exercise every leg of the engine × transport seams each run:
#   • Lane A — Postgres + Kafka + Mongo, relay Debezium CONNECT (:8081 / gRPC :9091)
#   • Lane B — MySQL   + NATS  + Mongo, relay Debezium SERVER  (:8082 / gRPC :9092)
#   • Lane C — SQL Server + DEDICATED Kafka + Mongo, relay Debezium CONNECT (:8084 / gRPC :9093)
#   • Lane D — Oracle Free 23ai + DEDICATED NATS + Mongo, relay Debezium SERVER (:8086 / gRPC :9097)
#
# Lanes run in WAVES of QA_MAX_PARALLEL_LANES (default 2, list order — A+B then
# C+D) on a COLD BENCH: each wave brings up ONLY its lanes' containers (engine +
# broker + relay + redis), runs, then stops them again before the next wave.
# Two reasons: (a) an 8 GB Docker VM cannot hold four lanes' peak activity
# (that's what OOM-killed containers); (b) an "idle" lane is never idle — the
# CDC relays poll continuously (LogMiner mining sessions, binlog/WAL readers,
# broker housekeeping), so hot neighbors tax the running wave's wall clock and
# skew the per-suite timings. The shared trio (mongo + keycloak + jaeger) stays
# up across waves; jaeger restarts between waves (drops its in-RAM trace
# store). The report accumulates across waves into the same side-by-side
# column groups, rendered live after every suite.
# Each lane runs on its OWN app ports, binary, relay and Redis, and its OWN Mongo
# DB (users_views / users_views_mysql), so they never collide — the whole suite
# list runs on each lane concurrently. Wall-clock ≈ the slower lane, not the sum.
#
# FAIL-FAST is the default: the FIRST suite that goes RED (on either lane) trips a
# shared sentinel and BOTH lanes stop at their next suite boundary (remaining runs
# reported "never ran", exit 1). Pass --keep-going (or KEEP_GOING=1) to run every
# scheduled suite regardless — the exhaustive sweep for sizing a change.
#
# Prerequisites: Docker and jq. The bench itself is managed HERE (wave up/stop
# per lane group; shared infra up front; lanes A/B restored at the end — the
# documented default bench). Each lane builds its own single-transport binary;
# the lane's relay is (re)started and proven streaming; the "running already"
# suites run against a per-lane server this script starts and stops; the
# self-managed suites get their lane's free port.
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
    all|postgres|mysql|sqlserver|oracle) BACKENDS="$arg" ;;
    --keep-going|-k)    KEEP_GOING=1 ;;
    *) echo "usage: qa/run.sh [all|postgres|mysql|sqlserver|oracle] [--keep-going]" >&2; exit 2 ;;
  esac
done
case "$BACKENDS" in
  # `all` schedules the full 4-lane matrix; a lane whose infrastructure is not
  # reachable SKIPs (⚠ in the report, never RED) via the availability filter
  # below. `./qa/run.sh sqlserver` / `oracle` still runs that lane alone.
  all)       BACKEND_LIST="postgres mysql sqlserver oracle" ;;
  postgres)  BACKEND_LIST="postgres" ;;
  mysql)     BACKEND_LIST="mysql" ;;
  sqlserver) BACKEND_LIST="sqlserver" ;;
  oracle)    BACKEND_LIST="oracle" ;;
esac

# Lane availability: a requested lane RUNS when its infrastructure answers and
# SKIPS otherwise — the skipped lane's report cells render as ⚠ SKIP (a
# warning, never a RED) so `all` works on any machine while showing exactly
# what did not run. sqlserver is the optional lane (compose profile; local by
# default, remote via QA_SQLSERVER_CONTEXT/QA_SQLSERVER_DB_HOST).
lane_available() {
  case "$1" in
    sqlserver)
      docker --context "${QA_SQLSERVER_CONTEXT:-default}" ps --format '{{.Names}}' 2>/dev/null | grep -q '^omnicore-qa-sqlserver$' \
        && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^omnicore-qa-kafka-sqlserver$' ;;
    oracle)
      docker --context "${QA_ORACLE_CONTEXT:-default}" ps --format '{{.Names}}' 2>/dev/null | grep -q '^omnicore-qa-oracle$' \
        && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^omnicore-qa-nats-oracle$' ;;
    *) return 0 ;;  # lanes A/B ride the base-bench check below
  esac
}
# Availability is judged PER WAVE, after the wave's infra starts (a cold bench
# has nothing running up front): a lane that does not answer post-up SKIPs —
# ⚠ cells, never RED — and the wave runs whoever answered.
RUN_BACKENDS="$BACKEND_LIST"; SKIP_BACKENDS=""

# Server-dependent suites run first (server up), self-managed after (port free).
# auth is last: it is the slowest (~5 min of validator-mode + cache-TTL waits).
SERVER_SUITES="e2e employee person graphql openapi httpclient"
SELF_SUITES="audit cache authz schema_evolution config_validation migrations tracing status_mapping probes http_hardening view_options httpclient_middleware lifecycle_hooks filter_operators aggregates upstream_composition composed_view external_embed integration_events transport auth grpc grpcclient grpc_security"
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

# ── Report safety net ────────────────────────────────────────────────────────
# The report is merged+written exactly once, near the end. Anything that exits
# BEFORE that (a preflight `exit 2`, Ctrl-C/kill, a lane that hangs) would leave
# a STALE qa-report.md from a prior run — silently reading as the last outcome.
# This trap guarantees qa-report.md always reflects THIS run: FINALIZED is set to
# 1 the instant the real report is written, so normal green/RED exits keep it and
# the handler only fires on an abnormal abort.
FINALIZED=0
ABORT_REASON=""

# render_report <status-md> — regenerate the WHOLE qa-report.md from the current
# per-lane fragments, then stamp <status-md> as the footer. Called after EVERY
# suite (so the file fills in LIVE, the way it did before the two-lane split) and
# once at the end with the final verdict. A mkdir lock serializes the two parallel
# lanes so they never write the report at the same instant; each call is a full
# overwrite rebuilt from every lane's rows-*.tsv, so the file is always a consistent
# snapshot of whatever has finished so far. The row appends (record/abort_lane →
# $LANE_ROWS) stay lock-free — each lane owns its own rows file.
render_report() {
  # NOTE: B is declared local — render_report is called from record(), which runs
  # inside run_lane's `local B` scope. Bash is dynamically scoped, so an unqualified
  # `for B` here would CLOBBER the lane's B (leaving it "mysql"), mislabeling every
  # subsequent row and colliding log paths. Keep B (and any loop var) local.
  local status="$1" lock="$LOG_DIR/report.lock" tries=0 B
  # Best-effort lock: if the sibling lane is mid-render, skip — the next suite's
  # render catches up. A lane is never blocked on the report.
  until mkdir "$lock" 2>/dev/null; do
    tries=$((tries+1)); [ "$tries" -ge 100 ] && return 0; sleep 0.02
  done
  local hdr="| Suite |" sep="|---|"
  {
    echo "# QA Matrix Report"
    echo
    echo "- **Updated:** $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- **Lanes:** $BACKEND_LIST (parallel)"
    echo "- **Suites:** $SUITES"
    echo "- **Scheduled runs:** $EXPECTED_RUNS"
    echo
    # Lane legend + build one SIDE-BY-SIDE header: each lane repeats today's
    # Backend/Pass/Fail/Verdict/Time columns, so the suite name is written once and
    # the matrix grows DOWN (one row per suite) AND ACROSS (a column group per lane).
    for B in $BACKEND_LIST; do
      case "$B" in
        postgres)  echo "- **Lane A** — Postgres + Kafka (Debezium Connect)" ;;
        mysql)     echo "- **Lane B** — MySQL + NATS (Debezium Server)" ;;
        sqlserver) echo "- **Lane C** — SQL Server + Kafka (Debezium Connect, dedicated broker)" ;;
        oracle)    echo "- **Lane D** — Oracle Free 23ai + NATS (Debezium Server, dedicated JetStream)" ;;
        *)         echo "- **Lane** — $B" ;;
      esac
      hdr="$hdr Backend | Pass | Fail | Verdict | Time |"
      sep="$sep---|---:|---:|:---:|---:|"
    done
    echo
    echo "$hdr"
    echo "$sep"
    # Body from every lane's rows-*.tsv, keyed by suite. awk keeps us off bash-4
    # associative arrays (macOS ships bash 3.2). A suite prints once it has at least
    # one lane result; a lane missing that suite (fail-fast/abort) gets a dash cell.
    # Rows not in the declared suite order (e.g. "(abort)") print after the rest.
    awk -F'\t' -v suites="$SUITES" -v backends="$BACKEND_LIST" '
      function emit(s,   line,any,j,b) {
        line = "| " s " |"; any = 0
        for (j=1;j<=nb;j++) {
          b = B[j]
          if ((s SUBSEP b) in cell) { line = line cell[s,b]; any = 1 }
          else                      { line = line " — | — | — | — | — |" }
        }
        if (any) print line
      }
      { seen[$1]=1
        mark = ($5=="OK") ? "✅ OK" : (($5=="SKIP") ? "⚠️ SKIP" : "❌ " $5)
        secstr = ($6=="-") ? "-" : $6 "s"
        cell[$1,$2] = " " $2 " | " $3 " | " $4 " | " mark " | " secstr " |" }
      END {
        ns=split(suites,S," "); nb=split(backends,B," ")
        for (i=1;i<=ns;i++) { inlist[S[i]]=1; emit(S[i]) }
        for (k in seen) if (!(k in inlist)) emit(k)
      }
    ' "$LOG_DIR"/rows-*.tsv 2>/dev/null
    echo
    echo "$status"
  } > "$REPORT_MD"
  rmdir "$lock" 2>/dev/null
}

# progress_footer — the live status line stamped after each suite completes.
progress_footer() {
  local done; done=$(cat "$LOG_DIR"/rows-*.tsv 2>/dev/null | grep -c .)
  echo "_🔄 Running… ${done}/${EXPECTED_RUNS} runs completed (refreshes after each suite)._"
}

# write_aborted_report — the trap safety net. The report is rendered LIVE during
# the run, so on an abnormal exit either (a) partial results are already on disk —
# re-stamp them ABORTED (fragments exist), or (b) nothing ran yet — write a bare
# preflight-abort notice. FINALIZED=1 disarms this once the final verdict is on
# disk, so a normal green/RED exit keeps the real report.
write_aborted_report() {
  [ "$FINALIZED" = 1 ] && return
  if ls "$LOG_DIR"/frag-*.md >/dev/null 2>&1; then
    render_report "**❌ RUN ABORTED — ${ABORT_REASON:-terminated before the matrix completed}. Partial results above. Logs: \`$LOG_DIR\`**"
  else
    { echo "# QA Matrix Report"; echo
      echo "- **Aborted:** $(date '+%Y-%m-%d %H:%M:%S')"
      echo
      echo "**❌ RUN ABORTED — ${ABORT_REASON:-terminated before the matrix completed}."
      echo "This report does NOT reflect a completed matrix. Logs: \`${LOG_DIR:-n/a}\`**"
    } > "$REPORT_MD"
  fi
}
trap write_aborted_report EXIT INT TERM

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
  render_report "$(progress_footer)"   # refresh qa-report.md live, as each suite lands
  [ "$word" = "OK" ]
}

abort_lane() { # abort_lane <backend> <reason>
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "(abort)" "$1" "-" "-" "ABORT" "-" >> "$LANE_ROWS"
  printf '| (abort: %s) | %s | - | - | ❌ ABORT | - |\n' "$2" "$1" >> "$LANE_FRAG"
  printf '%-18s %-9s %6s pass %5s fail   %s  %4ss  %s\n' "(abort)" "$1" "-" "-" "$(red "RED")" "-" "$2"
  render_report "$(progress_footer)"   # a lane abort shows up live too
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
  until curl -sf "$BASE/livez" >/dev/null 2>&1; do
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

# ── Wave infra lifecycle (cold bench between waves) ──────────────────────────
# Each lane's containers: engine + broker + relay + its Redis. The SHARED trio
# (mongo + keycloak + jaeger) is wave-independent — preflight starts it and it
# stays up. Both profiles ride every compose call so the C/D services resolve.
COMPOSE_CMD="docker compose -f devops/docker-compose.yml --profile sqlserver --profile oracle"
lane_services() {
  case "$1" in
    postgres)  echo "postgres kafka connect redis" ;;
    mysql)     echo "mysql nats debezium-server redis-mysql" ;;
    sqlserver) # a remote-DB lane starts everything but the (remote) engine
      if [ -n "${QA_SQLSERVER_DB_HOST:-}" ]; then echo "kafka-sqlserver connect-sqlserver redis-sqlserver"
      else echo "sqlserver kafka-sqlserver connect-sqlserver redis-sqlserver"; fi ;;
    oracle)
      if [ -n "${QA_ORACLE_DB_HOST:-}" ]; then echo "nats-oracle debezium-server-oracle redis-oracle"
      else echo "oracle nats-oracle debezium-server-oracle redis-oracle"; fi ;;
  esac
}
wave_up() {
  local svcs="" b
  for b in "$@"; do svcs="$svcs $(lane_services "$b")"; done
  bold "──────── wave infra up:$svcs ────────"
  # Warm starts (stop, never down — volumes/state kept). --wait gates on the
  # healthchecks (engines, brokers, connects); the relays are force-recreated
  # per lane by relay_setup anyway. A failure falls through to the per-wave
  # availability check, which turns the lane into ⚠ SKIP.
  $COMPOSE_CMD up -d --wait $svcs >/dev/null 2>&1 || true
}
wave_down() {
  [ "$#" -eq 0 ] && return 0
  local svcs="" b
  for b in "$@"; do svcs="$svcs $(lane_services "$b")"; done
  bold "──────── wave infra stop:$svcs ────────"
  $COMPOSE_CMD stop $svcs >/dev/null 2>&1 || true
  # Drop jaeger's in-RAM trace store between waves — the next wave's tracing
  # suite only queries its own lane's service anyway.
  docker restart omnicore-qa-jaeger >/dev/null 2>&1 || true
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
command -v jq >/dev/null || { ABORT_REASON="jq not installed"; echo "jq is required (brew install jq)" >&2; exit 2; }
# Shared, wave-independent infra up front; each wave manages only its lanes.
bold "shared infra up (mongo + keycloak + jaeger) ..."
docker compose -f devops/docker-compose.yml up -d --wait mongo keycloak jaeger >/dev/null 2>&1 \
  || { ABORT_REASON="shared infra failed to start"; echo "could not start mongo/keycloak/jaeger — is Docker running?" >&2; exit 2; }
if grep -qE 'auth|authz' <<<"$SUITES"; then
  bold "waiting for Keycloak (auth/authz suites requested) ..."
  ./devops/keycloak/wait-ready.sh >/dev/null 2>&1 || true
fi

bold "qa/run.sh — suites: $SUITES"
bold "lanes: $BACKEND_LIST (parallel)   logs: $LOG_DIR"
bold "report: $REPORT_MD"

# ── Launch the lanes in parallel ─────────────────────────────────────────────
overall_start=$(date +%s)
# Waves of QA_MAX_PARALLEL_LANES (see the header): each wave brings up ONLY its
# lanes' infra, runs the lanes in parallel, runs the source-mutating serial
# suites for those lanes, then stops the wave's containers. The next wave
# starts when the previous fully drains — and not at all once fail-fast
# tripped (its lanes report "never ran", like today).
QA_MAX_PARALLEL_LANES="${QA_MAX_PARALLEL_LANES:-2}"
serial_requested=""
for s in $SUITES; do grep -qw "$s" <<<"$SERIAL_SUITES" && serial_requested="$serial_requested $s"; done

set -- $RUN_BACKENDS
while [ "$#" -gt 0 ] && ! stop_requested; do
  WAVE=""; N=0
  while [ "$#" -gt 0 ] && [ "$N" -lt "$QA_MAX_PARALLEL_LANES" ]; do
    WAVE="$WAVE $1"; shift; N=$((N+1))
  done
  wave_up $WAVE
  # Post-up availability: an unreachable lane's report cells pre-fill as
  # ⚠ SKIP (one per suite) so the matrix stays complete and the verdict can
  # tell "skipped" from "never ran".
  WAVE_RUN=""
  for B in $WAVE; do
    if lane_available "$B"; then WAVE_RUN="$WAVE_RUN $B"; else
      SKIP_BACKENDS="$SKIP_BACKENDS $B"
      echo "lane unavailable — reporting ⚠ SKIP: $B" >&2
      : > "$LOG_DIR/rows-$B.tsv"
      for S in $SUITES; do printf '%s\t%s\t-\t-\tSKIP\t-\n' "$S" "$B" >> "$LOG_DIR/rows-$B.tsv"; done
      render_report "$(progress_footer)"
    fi
  done
  WAVE_RUN="${WAVE_RUN# }"
  [ -z "$WAVE_RUN" ] && continue
  bold "──────── lane wave: $WAVE_RUN ────────"
  LANE_PIDS=""
  for B in $WAVE_RUN; do
    run_lane "$B" &
    LANE_PIDS="$LANE_PIDS $!"
  done
  for pid in $LANE_PIDS; do wait "$pid"; done

  # Serial phase for THIS wave: schema_evolution patches internal/infra/views.go
  # (shared source + backup path) and rebuilds, so it runs one lane at a time,
  # only after the wave's parallel builds drained — and before the wave's infra
  # stops (it needs the lane's engine + relay live).
  if [ -n "$serial_requested" ] && ! stop_requested; then
    bold "──────── serial phase (source-mutating suites):$serial_requested ────────"
    for B in $WAVE_RUN; do
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

  # Fail-fast leaves the wave's infra UP — the crime scene stays intact for
  # diagnosis. A clean wave stops its containers (warm stop, volumes kept).
  stop_requested || wave_down $WAVE_RUN
done

# Restore the documented default bench (lanes A/B up, C/D down) — unless
# fail-fast tripped, in which case the failing wave's infra is still up.
stop_requested || docker compose -f devops/docker-compose.yml up -d >/dev/null 2>&1 || true

elapsed=$(( $(date +%s) - overall_start ))

# The report has been rendered LIVE after every suite (render_report); the final
# verdict is stamped onto that same file by the branches below.

# ── Accounting from the per-lane rows ────────────────────────────────────────
cat "$LOG_DIR"/rows-*.tsv > "$LOG_DIR/rows.tsv" 2>/dev/null || : > "$LOG_DIR/rows.tsv"
COMPLETED_RUNS=$(grep -cv $'\tABORT\t' "$LOG_DIR/rows.tsv" 2>/dev/null); COMPLETED_RUNS=${COMPLETED_RUNS:-0}
RED_RUNS=$(awk -F'\t' '$5 != "OK" && $5 != "SKIP"' "$LOG_DIR/rows.tsv" | grep -c . 2>/dev/null); RED_RUNS=${RED_RUNS:-0}
SKIP_RUNS=$(awk -F'\t' '$5 == "SKIP"' "$LOG_DIR/rows.tsv" | grep -c . 2>/dev/null); SKIP_RUNS=${SKIP_RUNS:-0}
MISSING_RUNS=$((EXPECTED_RUNS - COMPLETED_RUNS))

bold ""
bold "════════════════ QA MATRIX REPORT ════════════════"
awk -F'\t' '{printf "  %-18s %-9s %6s pass %5s fail   %-5s %4ss\n", $1, $2, $3, $4, $5, $6}' "$LOG_DIR/rows.tsv"
bold "═══════════════════════════════════════════════════"

if [ "$RED_RUNS" = "0" ] && [ "$MISSING_RUNS" = "0" ] && [ "$COMPLETED_RUNS" != "0" ]; then
  logs_note="$LOG_DIR"
  skip_note=""; [ "${SKIP_RUNS:-0}" != "0" ] && skip_note=" (⚠ $SKIP_RUNS run(s) SKIPPED: lane(s) $SKIP_BACKENDS unavailable)"
  render_report "**✅ ALL GREEN — $COMPLETED_RUNS/$EXPECTED_RUNS runs — ${elapsed}s total.${skip_note}**"
  FINALIZED=1   # real verdict on disk — disarm the aborted-report safety net
  if [ "$LOG_DIR_EPHEMERAL" = "1" ]; then rm -rf "$LOG_DIR"; logs_note="removed (all green)"; fi
  printf '%s — %s/%s runs, %ss%s, report: %s, logs: %s\n' \
    "$(green "ALL GREEN")" "$COMPLETED_RUNS" "$EXPECTED_RUNS" "$elapsed" "$skip_note" "$REPORT_MD" "$logs_note"
  exit 0
else
  detail="$RED_RUNS red"
  [ "$MISSING_RUNS" != "0" ] && detail="$detail, $MISSING_RUNS never ran"
  [ -f "$LOG_DIR/failfast" ] && detail="$detail (fail-fast — pass --keep-going for the full sweep)"
  render_report "**❌ RED — $detail of $EXPECTED_RUNS scheduled runs — ${elapsed}s total. Logs: \`$LOG_DIR\`**"
  FINALIZED=1   # real verdict on disk — disarm the aborted-report safety net
  printf '%s — %s of %s scheduled runs, %ss, report: %s, logs: %s\n' \
    "$(red "RED")" "$detail" "$EXPECTED_RUNS" "$elapsed" "$REPORT_MD" "$LOG_DIR"
  exit 1
fi
