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

# Absolute path to THIS script's dir (qa/), resolved BEFORE the cd below. The cd
# moves the cwd to the repo root, which would make a later `dirname "$BASH_SOURCE"`
# resolve against the WRONG directory — so the SQLite step below must reference
# this captured path, not re-derive it post-cd. Works no matter the caller's cwd or
# how run.sh was invoked (`./run.sh` from inside qa/, `bash qa/run.sh` from root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$0")/.."
STACK_ROOT="$(cd ../ && pwd)"

BACKENDS="all"
KEEP_GOING="${KEEP_GOING:-0}"
for arg in "$@"; do
  case "$arg" in
    all|postgres|mysql|sqlserver|oracle|sqlite) BACKENDS="$arg" ;;
    --keep-going|-k)    KEEP_GOING=1 ;;
    *) echo "usage: qa/run.sh [all|postgres|mysql|sqlserver|oracle|sqlite] [--keep-going]" >&2; exit 2 ;;
  esac
done

# ── SQLite is an ISOLATED individual step, NOT a lane ────────────────────────
# The four run.sh lanes are each an engine + broker + Mongo projection pipeline,
# and EVERY *.sh suite reads its result through the MONGO VIEW (outbox → CDC relay
# → broker → SyncEngine → Mongo). SQLite has NO CDC source (Debezium cannot tail
# a SQLite file), so Mongo-projected views never materialize on it — by design.
# SQLite's read side is the RELATIONAL view (served straight from the SoR), so it
# CANNOT run the projection-dependent suites as a lane. It runs APART, as ONE
# self-contained step (qa/sqlite.sh): boot the SQLite engine as SoR and assert the
# WRITE side over real HTTP, verified directly against the app.db file with
# sqlite3 (the read side that does not need a projection).
#
#   ./qa/run.sh sqlite   → runs ONLY this isolated step (no lanes, no bench waves)
#   ./qa/run.sh          → runs the four DB lanes, THEN this step at the very end
#
# `./qa/run.sh sqlite` has an EMPTY lane list (BACKEND_LIST=""): it skips the unit
# gate, the cold-bench waves and the CDC relays, and runs ONLY the isolated step —
# but it flows through the SAME report machinery as a full run, so it produces the
# consolidated qa-report.md (the SQLite section), instead of the bare, report-less
# `exec` it used to do (a `sqlite` run left qa-report.md untouched from a prior run).
case "$BACKENDS" in
  # `all` schedules the full 4-lane matrix; a lane whose infrastructure is not
  # reachable SKIPs (⚠ in the report, never RED) via the availability filter
  # below. `./qa/run.sh sqlserver` / `oracle` still runs that lane alone.
  all)       BACKEND_LIST="postgres mysql sqlserver oracle" ;;
  postgres)  BACKEND_LIST="postgres" ;;
  mysql)     BACKEND_LIST="mysql" ;;
  sqlserver) BACKEND_LIST="sqlserver" ;;
  oracle)    BACKEND_LIST="oracle" ;;
  sqlite)    BACKEND_LIST="" ;;   # not a lane — only the isolated SQLite step runs
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
SELF_SUITES="audit cache authz schema_evolution relational_evolution rebuild_scale projection_resilience projection_ripple config_validation migrations tracing status_mapping probes http_hardening view_options relational_view projection_convergence httpclient_middleware lifecycle_hooks filter_operators aggregates upstream_composition composed_view external_embed link_in_child view_embed fields integration_events transport auth grpc grpcclient grpc_security"
ALL_SUITES="$SERVER_SUITES $SELF_SUITES"
SUITES="${SUITES:-$ALL_SUITES}"

# Suites that MUST run alone: schema_evolution + rebuild_scale both mutate the
# SHARED source tree (views/schema/DTOs) + a shared backup path and rebuild, so
# neither can run concurrently with any other build (the other lane would compile
# the patched source). They run SERIALLY after the parallel matrix, one lane at a
# time. rebuild_scale is also heavy (a full-aggregate bulk seed + multi-pod
# blue-green rebuild), so run.sh drives it at a bounded SEED_COUNT (see below).
# projection_resilience degrades the SHARED Mongo replica set (primary step-down,
# quorum loss) for bounded windows — running it beside a parallel wave would fail
# every sibling lane's projections, so it is serial for a different reason.
SERIAL_SUITES="schema_evolution relational_evolution rebuild_scale projection_resilience"

# rebuild_scale's per-lane seed under run.sh (its standalone default is 1,000,000
# — far too heavy for the matrix). The SAME seed on every lane, on purpose: the
# suite doubles as a cross-engine performance yardstick (the backfill throughput
# is directly comparable only at equal N). Override: REBUILD_SCALE_SEED=30000 ./qa/run.sh
#
# PINNED ABOVE rebuild_scale's WINDOW_MIN (250000), and that is a correctness
# choice, not a sizing one. Below WINDOW_MIN the suite cannot reliably observe the
# live writes landing on the OLD slot during the dual-apply window — the backfill
# flips before they arrive — so it reports that check INFORMATIONALLY instead of
# asserting it. The suite then goes green without ever having exercised the flip
# window, which is exactly how the blue-green loss bug stayed hidden: the green run
# was the absence of the window, not the absence of the bug. At/above WINDOW_MIN the
# check becomes a HARD assertion (`peak > seed`), so the regression it guards is
# actually proven on every matrix run.
REBUILD_SCALE_SEED="${REBUILD_SCALE_SEED:-250001}"

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
  local status="$1" lock="$LOG_DIR/report.lock" tries=0 B smark
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
    if [ -n "$BACKEND_LIST" ]; then
      echo "- **Lanes:** $BACKEND_LIST (parallel)"
      echo "- **Suites:** $SUITES"
      echo "- **Scheduled runs:** $EXPECTED_RUNS"
    else
      # `./qa/run.sh sqlite`: no lanes, so there is no side-by-side matrix — only
      # the SQLite isolated step below. Keep the same report shape, just skip the
      # matrix header/body entirely.
      echo "- **Mode:** SQLite isolated step only (relational-only — no CDC/Mongo projection; not a lane)"
    fi
    echo
    if [ -n "$BACKEND_LIST" ]; then
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
      # SQLite is the isolated 5th track (Lane E) on a full run — listed in the
      # legend so it is visible up front, but reported in its OWN section below the
      # matrix: it is relational-only (no CDC → no Mongo projection), so it cannot be
      # a side-by-side matrix column that runs every suite like the DB lanes.
      [ "$BACKENDS" = "all" ] && echo "- **Lane E** — SQLite (ISOLATED, relational-only — no CDC/projection; verdict below the matrix)"
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
    fi
    # SQLite is NOT a lane (relational-only, no CDC → no Mongo projection), so it
    # is reported in its OWN section BELOW the lane matrix, not as a matrix column.
    # SQLITE_VERDICT is set by the isolated step that runs after the lanes.
    if [ "$BACKENDS" = "all" ] || [ -n "${SQLITE_VERDICT:-}" ]; then
      case "${SQLITE_VERDICT:-}" in
        OK) smark="✅ OK" ;;
        "") smark="⏳ pending (runs after the DB lanes)" ;;
        *)  smark="❌ $SQLITE_VERDICT" ;;
      esac
      echo
      if [ -n "$BACKEND_LIST" ]; then
        echo "### Lane E — SQLite (isolated; relational-only, not a projection lane)"
      else
        echo "### SQLite isolated step (relational-only, not a projection lane)"
      fi
      echo
      echo "Boots the SQLite engine as SoR (\`-tags 'sqlite nats'\`, \`CGO_ENABLED=0\`) and asserts the write side over HTTP — verified directly in the \`app.db\` file. No CDC/Mongo projection, so it runs apart from the matrix. See \`qa/sqlite.sh\`."
      echo
      echo "| Step | Backend | Pass | Fail | Verdict | Time |"
      echo "|---|---|---:|---:|:---:|---:|"
      echo "| sqlite (boot + migrations + write-side, checked in app.db) | sqlite | ${SQLITE_PASS:-–} | ${SQLITE_FAIL:-–} | $smark | ${SQLITE_SECS:+${SQLITE_SECS}s} |"
    fi
    echo
    echo "$status"
  } > "$REPORT_MD"
  rmdir "$lock" 2>/dev/null
}

# progress_footer — the live status line stamped after each suite completes.
# Counts only completed SUITE runs (against EXPECTED_RUNS = N_SUITES × N_BACKENDS),
# excluding the fw/ex-integration preflight rows and any ABORT rows — same basis as
# the final verdict, so the live count never overshoots the scheduled total.
progress_footer() {
  local done; done=$(cat "$LOG_DIR"/rows-*.tsv 2>/dev/null | grep -vE $'^(fw|ex)-integration\t' | grep -cv $'\tABORT\t')
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
  # The qa fixture views go too, so a leftover blue-green SLOT pointer from a prior
  # run does not survive into a fresh boot (the view FreshInit's bare instead).
  qa_db_exec "DELETE FROM omnicore_mongo_views WHERE view_name IN ('users','employees','persons') OR view_name LIKE 'gadget%' OR view_name LIKE 'qa%' OR view_name LIKE 'upstream%';" 2>/dev/null || true
  # Clear the qa fixture SOURCE tables too. Blue-green classifies "Mongo empty +
  # relational rows" as DriftMongoWiped and rebuilds online at boot — under Option A
  # /readyz stays 503 until it finishes. A prior run's leftover source rows (e.g.
  # orphan gadget_notes a suite dropped from Mongo but not from PG) would otherwise
  # make a NON-seeding suite (probes) boot straight into a rebuild. Child-first for
  # the FK; best-effort (a table may not exist on a minimal build).
  qa_db_exec "DELETE FROM gadget_notes;" 2>/dev/null || true
  qa_db_exec "DELETE FROM gadgets;" 2>/dev/null || true

  # ── Per-lane integration tests — the `integration`-tagged Go suites, run on a
  # fully-prepped lane BEFORE the server starts serving E2E ─────────────────────
  # Framework: self-manages throwaway databases (admin DSN) + throwaway Mongo
  #   collections, so it never touches users_db. Its Mongo default is the DEV
  #   bench (27018) → point it at this lane's qa Mongo; its MySQL admin DSN
  #   default is the DEV port 3307 → point it at the qa bench 3317 (harmless on
  #   the non-MySQL lanes, which read their own engine's default). PG :5433,
  #   SQL Server :14333 and Oracle :15211 defaults already match the qa bench.
  # Example: reads DATABASE_URL (already this lane's users_db) + the yaml dialect
  #   via ${REL_DIALECT}, so it follows the lane's engine. It is DESTRUCTIVE —
  #   resetState does DELETE FROM the domain tables — which is exactly why it runs
  #   HERE, before the server boots, so it can never collide with the live E2E
  #   suites (which seed their own data on a clean DB). Both the plain and the qa
  #   builds run. Reported as the `fw-integration` / `ex-integration` rows.
  if ! stop_requested; then
    local it0=$(date +%s)
    ( cd "$STACK_ROOT/omnicore"
      export OMNICORE_TEST_MONGO_URI="$MONGO_URI"
      export OMNICORE_TEST_MYSQL_ADMIN_DSN="root:root@tcp(127.0.0.1:3317)/?parseTime=true&multiStatements=true"
      go test -tags "integration $QA_BUILD_TAGS" ./... -count=1 -timeout 600s
    ) > "$LOG_DIR/fw-integration-$B.log" 2>&1; local irc=$?
    if ! record "fw-integration" "$B" "$LOG_DIR/fw-integration-$B.log" "$irc" "$(( $(date +%s) - it0 ))"; then
      fail_fast "fw-integration" "$B" && return 1
    fi
  fi
  if ! stop_requested; then
    local et0=$(date +%s) erc=0
    APP_PROFILE=dev OMNICORE_TEST_MONGO_URI="$MONGO_URI" \
      go test -tags "integration $QA_BUILD_TAGS"    ./... -count=1 >  "$LOG_DIR/ex-integration-$B.log" 2>&1 || erc=1
    APP_PROFILE=dev OMNICORE_TEST_MONGO_URI="$MONGO_URI" \
      go test -tags "integration $QA_BUILD_TAGS qa" ./... -count=1 >> "$LOG_DIR/ex-integration-$B.log" 2>&1 || erc=1
    if ! record "ex-integration" "$B" "$LOG_DIR/ex-integration-$B.log" "$erc" "$(( $(date +%s) - et0 ))"; then
      fail_fast "ex-integration" "$B" && return 1
    fi
  fi

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

# run_sqlite_step — run the isolated SQLite step (qa/sqlite.sh) and parse its
# result through the SAME summarize() every lane suite uses. sqlite.sh emits the
# standard `PASS=N  FAIL=M` summary line (like every other suite), so there is no
# bespoke parsing here — summarize() handles it. Sets SQLITE_PASS/FAIL/SECS/VERDICT
# for the report's SQLite section and returns the step's exit code. Called from BOTH
# `./qa/run.sh sqlite` (only this) and the tail of a full `all` run, so the two
# entry points can never drift.
run_sqlite_step() {
  bold ""
  bold "════════════════ SQLite isolated step (relational-only) ════════════════"
  local t0=$SECONDS counts rc
  bash "$SCRIPT_DIR/sqlite.sh" > "$LOG_DIR/sqlite.log" 2>&1
  rc=$?
  SQLITE_SECS=$((SECONDS - t0))
  tail -3 "$LOG_DIR/sqlite.log"
  counts=$(summarize "$LOG_DIR/sqlite.log" "$rc")
  SQLITE_PASS=${counts%% *}; SQLITE_FAIL=${counts##* }
  if [ "$rc" = "0" ]; then SQLITE_VERDICT="OK"; else SQLITE_VERDICT="RED"; fi
  return "$rc"
}

# ── Preflight ────────────────────────────────────────────────────────────────
# jq is a LANE prerequisite (cdc_warmup parses view docs with it); the SQLite-only
# run has no lanes and no CDC, so it does not require jq.
[ -n "$BACKEND_LIST" ] && { command -v jq >/dev/null || { ABORT_REASON="jq not installed"; echo "jq is required (brew install jq)" >&2; exit 2; }; }

# ── Unit-test gate: framework THEN example, EVERY build tag, before any bench ──
# "green" is never a subset — this runs the full //go:build tag matrix from the
# stack-root CLAUDE.md (unit only; no `integration` tag → no DB needed). It runs
# BEFORE Docker is touched: a single FAIL aborts the whole run and the bench
# never comes up. (The per-lane `integration` matrix runs later, inside run_lane,
# once each lane's engine + Mongo are up — see below.)
FW_UNIT_TAGS=("postgres kafka" "mysql nats" "sqlserver kafka" "oracle nats" "postgres nats" "mysql kafka")
EX_UNIT_TAGS=("postgres kafka" "postgres nats" "postgres kafka qa" "postgres nats qa")
run_unit_matrix() { # run_unit_matrix <dir> <name> <tag-combo>...
  local dir="$1" name="$2"; shift 2
  local tags
  for tags in "$@"; do
    bold "unit [$name] -tags '$tags' ..."
    if ! ( cd "$dir" && go test -tags "$tags" ./... -count=1 ); then
      ABORT_REASON="unit tests RED: $name -tags '$tags'"
      echo "UNIT TESTS RED — $name -tags '$tags'; aborting before the bench" >&2
      exit 1
    fi
  done
}
# The unit-test gate and the shared lane infra are LANE machinery — a SQLite-only
# run skips both (the isolated step self-builds its `sqlite nats` binary and boots
# against just Mongo + NATS). It brings up only what sqlite.sh needs to boot.
if [ -n "$BACKEND_LIST" ]; then
  bold "unit-test gate — framework then example, all tags (no bench yet) ..."
  run_unit_matrix "$STACK_ROOT/omnicore" framework "${FW_UNIT_TAGS[@]}"
  run_unit_matrix "." example "${EX_UNIT_TAGS[@]}"

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
else
  # SQLite boots against the QA-bench Mongo + NATS; bring just those up (best-effort)
  # so `./qa/run.sh sqlite` is self-sufficient even on a cold bench.
  bold "shared infra up (mongo + nats — the SQLite step boots against them) ..."
  docker compose -f devops/docker-compose.yml up -d --wait mongo nats >/dev/null 2>&1 || true
  bold "qa/run.sh — SQLite isolated step only (relational-only; not a projection lane)"
  bold "report: $REPORT_MD   logs: $LOG_DIR"
fi

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
          # rebuild_scale is lane-driven + heavy: pin its seed to the matrix budget
          # (its own default is 1M for standalone runs) — the SAME N on every lane,
          # so the per-lane timings are a comparable performance yardstick.
          suite_env=""
          [ "$s" = "rebuild_scale" ] && suite_env="SEED_COUNT=$REBUILD_SCALE_SEED"
          env $suite_env ./qa/$s.sh > "$LOG_DIR/$s-$B.log" 2>&1; rc=$?
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
# fail-fast tripped, in which case the failing wave's infra is still up. A
# SQLite-only run never touched the lane bench, so it has nothing to restore.
[ -n "$BACKEND_LIST" ] && { stop_requested || docker compose -f devops/docker-compose.yml up -d >/dev/null 2>&1 || true; }

# The report has been rendered LIVE after every suite (render_report); the final
# verdict is stamped onto that same file by the branches below. `elapsed` is
# computed AFTER the SQLite step below, so the wall-clock total includes it (on a
# SQLite-only run it IS the whole run).

# ── Accounting from the per-lane rows ────────────────────────────────────────
cat "$LOG_DIR"/rows-*.tsv > "$LOG_DIR/rows.tsv" 2>/dev/null || : > "$LOG_DIR/rows.tsv"
# COMPLETED counts only scheduled SUITE runs — the fw-integration / ex-integration
# preflight rows are extra (not part of N_SUITES × N_BACKENDS), so excluding them
# keeps COMPLETED comparable to EXPECTED_RUNS (a fully-green matrix lands
# COMPLETED == EXPECTED == 0 missing). A RED preflight still trips RED_RUNS below.
COMPLETED_RUNS=$(grep -vE $'^(fw|ex)-integration\t' "$LOG_DIR/rows.tsv" 2>/dev/null | grep -cv $'\tABORT\t'); COMPLETED_RUNS=${COMPLETED_RUNS:-0}
RED_RUNS=$(awk -F'\t' '$5 != "OK" && $5 != "SKIP"' "$LOG_DIR/rows.tsv" | grep -c . 2>/dev/null); RED_RUNS=${RED_RUNS:-0}
SKIP_RUNS=$(awk -F'\t' '$5 == "SKIP"' "$LOG_DIR/rows.tsv" | grep -c . 2>/dev/null); SKIP_RUNS=${SKIP_RUNS:-0}
# ── SQLite isolated step at the END of a full run ────────────────────────────
# After the four projection lanes finish, run the SQLite step (see its header and
# the note by the arg parser: SQLite is relational-only, so it is NOT a lane). It
# counts as ONE scheduled run — Lane E — in the final tally: it bumps
# EXPECTED_RUNS and, on success, COMPLETED_RUNS (RED_RUNS on failure), so the
# verdict's X/Y and the ALL-GREEN/RED decision include it exactly like a lane
# suite. It runs only for a full `all` run; a single-lane invocation stays scoped.
if [ "$BACKENDS" = "all" ] || [ "$BACKENDS" = "sqlite" ]; then
  run_sqlite_step; sqlite_rc=$?
  EXPECTED_RUNS=$((EXPECTED_RUNS + 1))
  # The step RAN (OK or RED), so it counts as completed — exactly like a suite
  # row (which counts in COMPLETED whether OK or RED). A RED only adds to RED_RUNS;
  # counting it as completed too keeps it from ALSO showing as "never ran".
  COMPLETED_RUNS=$((COMPLETED_RUNS + 1))
  [ "$sqlite_rc" = "0" ] || RED_RUNS=$((RED_RUNS + 1))
fi

# Computed AFTER the SQLite step so its +1 (Lane E) is included in the tally.
MISSING_RUNS=$((EXPECTED_RUNS - COMPLETED_RUNS))
elapsed=$(( $(date +%s) - overall_start ))

bold ""
bold "════════════════ QA MATRIX REPORT ════════════════"
[ -n "${SQLITE_VERDICT:-}" ] && bold "$(printf '  %-18s %-9s %6s pass %5s fail   %-5s %4ss' 'sqlite' 'sqlite' "${SQLITE_PASS:-?}" "${SQLITE_FAIL:-?}" "$SQLITE_VERDICT" "${SQLITE_SECS:-0}")"
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
