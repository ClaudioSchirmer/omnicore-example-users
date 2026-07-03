#!/usr/bin/env bash
# ============================================================================
# Performance / load suite for omnicore-example-users.
#
# NOT a pass/fail oracle like the other qa/*.sh — it MEASURES latency and
# throughput of the hot paths and writes a markdown report. It is deliberately
# kept OUT of qa/run.sh: perf numbers are indicative, not a green/red verdict.
#
# What it measures, per backend (BACKEND=postgres|mysql, matching the running
# server's boot dialect):
#
#   WRITE       POST /users          — the synchronous write path (one TX:
#                                       data + outbox + audit). Each request
#                                       carries a UNIQUE document (the SharedBase
#                                       natural key) so none collide on the
#                                       person PK (409).
#   CDC-LAG     outbox → Mongo        — after the write burst, how long until a
#                                       sample of the just-written rows is
#                                       readable via GET /users/:id (Debezium →
#                                       Kafka → SyncEngine → Mongo projection).
#   READ-BY-ID  GET /users/:id        — steady-state read of the projected
#                                       documents (cycles the seeded ids).
#   READ-LIST   GET /users?limit=N    — keyset-paginated listing.
#
# Metrics come from vegeta (p50/p95/p99, throughput, status histogram) — a real
# load generator, not bottlenecked by per-request process spawn.
#
# HONEST CAVEAT: this runs against a single-instance docker-compose bench with
# no tuning or replication. The numbers are RELATIVE — good for catching a
# regression between versions or comparing PG vs MySQL — NOT production capacity
# planning.
#
# Requires: the service running on :8080 (dual-engine binary booted for the
# target BACKEND), docker compose up, the Debezium connector registered, and
# `vegeta` on PATH (go install github.com/tsenart/vegeta/v12@latest).
#
# Run (per backend):
#   go build -tags 'postgres mysql' -o /tmp/srv ./bootstrap
#   export BACKEND=postgres; source qa/_backend.sh; APP_PROFILE=dev /tmp/srv &   # in another shell
#   bash qa/perf.sh                                # postgres, fresh report
#   # then reboot the server for mysql and:
#   BACKEND=mysql PERF_FRESH=0 bash qa/perf.sh     # appends the mysql section
#
# Tunables (env): PERF_RATE (req/s, 200) · PERF_DURATION (s, 20) ·
#   PERF_WARMUP (s, 5) · PERF_SEED (read corpus size, 300) ·
#   PERF_TIMEOUT (30s) · PERF_MAX_WORKERS (unset = vegeta open model) ·
#   PERF_CDC_TIMEOUT (s, 60) · PERF_FRESH (1 = truncate report first) ·
#   BASE (http://localhost:8080)
# ============================================================================
set -u

source "$(dirname "$0")/_backend.sh"

BASE="${BASE:-http://localhost:8080}"
RATE="${PERF_RATE:-200}"
DURATION="${PERF_DURATION:-20}"
WARMUP="${PERF_WARMUP:-5}"
SEED="${PERF_SEED:-300}"
TIMEOUT="${PERF_TIMEOUT:-30s}"
CDC_TIMEOUT="${PERF_CDC_TIMEOUT:-60}"
FRESH="${PERF_FRESH:-1}"
REPORT="${PERF_REPORT:-$(dirname "$0")/../../perf-report.md}"
MAXW_ARG=""
[ -n "${PERF_MAX_WORKERS:-}" ] && MAXW_ARG="-max-workers=${PERF_MAX_WORKERS}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

hr()  { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec() { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
info(){ printf '\033[0;37m%s\033[0m\n' "$1"; }
die() { printf '\033[1;31mperf: %s\033[0m\n' "$1" >&2; exit 1; }

# ── Preconditions ───────────────────────────────────────────────────────────
# Resolve vegeta from PATH, or fall back to $(go env GOPATH)/bin so a plain
# `go install …/vegeta@latest` works without touching PATH.
VEGETA="$(command -v vegeta || true)"
[ -z "$VEGETA" ] && [ -x "$(go env GOPATH 2>/dev/null)/bin/vegeta" ] && VEGETA="$(go env GOPATH)/bin/vegeta"
[ -n "$VEGETA" ] || die "vegeta not found — install: go install github.com/tsenart/vegeta/v12@latest (user-space, no sudo; lands in \$(go env GOPATH)/bin)"
command -v jq      >/dev/null || die "jq not found"
command -v python3 >/dev/null || die "python3 not found"
curl -sf -o /dev/null "$BASE/users" || die "server not reachable at $BASE — boot the dual-engine binary for BACKEND=$BACKEND first"

# A run-unique numeric-ish nonce keeps documents unique across runs even if the
# table is not reset (Date-derived; documents match ^[A-Za-z0-9.\-]{3,32}$).
NONCE="$(date +%s)"
N_WARM=$(( RATE * WARMUP ))
N_MEAS=$(( RATE * DURATION ))

# ── vegeta helpers ──────────────────────────────────────────────────────────
# gen_writes <count> <offset> <outfile> — vegeta JSON targets, one unique
# POST /users per line (body base64-encoded inline).
gen_writes() {
  python3 - "$1" "$2" "$NONCE" "$BASE/users" > "$3" <<'PY'
import base64, json, sys
n, off, nonce, url = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
for k in range(n):
    i = off + k
    body = {
        "name": f"Perf User {i}",
        "email": f"perf-{nonce}-{i}@example.com",
        "phone": "14155552671",
        "document": f"perf-{nonce}-{i}",          # unique natural key, regex-valid
        "userName": f"perf_{nonce}_{i}",
        "emailNotification": True, "smsNotification": False,
        "addresses": [{"label": "home", "street": "1 Infinite Loop", "number": "1",
                       "neighborhood": "Mariani", "city": "Cupertino", "state": "CA",
                       "zipCode": "95014", "country": "US"}],
    }
    b = base64.b64encode(json.dumps(body).encode()).decode()
    print(json.dumps({"method": "POST", "url": url, "body": b,
                      "header": {"Content-Type": ["application/json"]}}))
PY
}

# attack_json <targetsfile> <outbin> — POST attack (vegeta JSON target format).
attack_json() { "$VEGETA" attack -format=json -targets="$1" -rate="$RATE" -duration="${DURATION}s" -timeout="$TIMEOUT" $MAXW_ARG > "$2"; }
# attack_http <targetsfile> <outbin> — GET attack (plain "METHOD url" lines).
attack_http() { "$VEGETA" attack -targets="$1" -rate="$RATE" -duration="${DURATION}s" -timeout="$TIMEOUT" $MAXW_ARG > "$2"; }
# warm_json/warm_http — short throwaway burst, discarded.
warm_json() { [ "$WARMUP" -gt 0 ] || return 0; "$VEGETA" attack -format=json -targets="$1" -rate="$RATE" -duration="${WARMUP}s" -timeout="$TIMEOUT" $MAXW_ARG >/dev/null; }
warm_http() { [ "$WARMUP" -gt 0 ] || return 0; "$VEGETA" attack -targets="$1" -rate="$RATE" -duration="${WARMUP}s" -timeout="$TIMEOUT" $MAXW_ARG >/dev/null; }

# record <label> <bin> — prints the console report and appends a summary row +
# a detail block to the report globals ROWS / BLOCKS.
ROWS=""; BLOCKS=""
record() {
  local label="$1" bin="$2"
  "$VEGETA" report "$bin"                                       # console
  local line; line=$("$VEGETA" report -type=json "$bin" | jq -r '
      [ .requests,
        (.throughput),
        (.latencies["50th"]/1000000),
        (.latencies["95th"]/1000000),
        (.latencies["99th"]/1000000),
        (.success*100),
        (.status_codes | to_entries | map("\(.key):\(.value)") | join(" ")) ] | @tsv')
  local reqs thr p50 p95 p99 succ codes
  IFS=$'\t' read -r reqs thr p50 p95 p99 succ codes <<< "$line"
  ROWS+="$(printf '| %s | %s | %s | %d | %.0f | %.1f | %.1f | %.1f | %.1f%% | %s |' \
            "$label" "$BACKEND" "$RATE" "$reqs" "$thr" "$p50" "$p95" "$p99" "$succ" "$codes")"$'\n'
  BLOCKS+=$'\n'"#### ${label} — ${BACKEND}"$'\n\n```\n'"$("$VEGETA" report "$bin")"$'\n```\n'
}

sec "OmniCore perf suite — backend=$BACKEND  rate=${RATE}/s  duration=${DURATION}s  warmup=${WARMUP}s  seed=${SEED}"
info "Report → $REPORT"

# ── Clean slate ─────────────────────────────────────────────────────────────
info "Resetting domain + Mongo projections…"
qa_db_reset_domain
qa_mongo_reset

# ── 1) WRITE ────────────────────────────────────────────────────────────────
sec "1/4  WRITE — POST /users"
gen_writes "$N_WARM" 0            "$WORK/w_warm.jsonl"
gen_writes "$N_MEAS" 1000000     "$WORK/w_meas.jsonl"
info "warming up (${WARMUP}s)…"; warm_json "$WORK/w_warm.jsonl"
info "measuring (${DURATION}s, ${N_MEAS} unique creates)…"
attack_json "$WORK/w_meas.jsonl" "$WORK/w.bin"
record "WRITE  POST /users" "$WORK/w.bin"

# ── 2) CDC lag + capture read corpus ────────────────────────────────────────
sec "2/4  CDC-LAG — outbox → Mongo projection"
info "Capturing up to ${SEED} ids from the relational store…"
# Portable capture (macOS ships bash 3.2 — no `mapfile`).
IDS=()
while IFS= read -r _id; do [ -n "$_id" ] && IDS+=("$_id"); done \
  < <(qa_db_query "SELECT $(qa_uuid_select id) FROM users LIMIT ${SEED}")
[ "${#IDS[@]}" -gt 0 ] || die "no rows found after WRITE — is CDC/write path healthy?"
info "Captured ${#IDS[@]} ids. Polling projection until all readable (timeout ${CDC_TIMEOUT}s)…"
cdc_start=$(date +%s); projected=0
for id in "${IDS[@]}"; do
  deadline=$(( $(date +%s) + CDC_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/users/$id")" = "200" ] && { projected=$((projected+1)); break; }
    sleep 0.2
  done
done
cdc_elapsed=$(( $(date +%s) - cdc_start ))
info "Projection caught up: ${projected}/${#IDS[@]} readable after ${cdc_elapsed}s."
CDC_NOTE="${projected}/${#IDS[@]} rows projected; sample caught up in ~${cdc_elapsed}s (post-burst, includes drain)"

# Build read-by-id targets (plain vegeta http format), cycled by vegeta.
: > "$WORK/r_id.http"
for id in "${IDS[@]}"; do printf 'GET %s/users/%s\n' "$BASE" "$id" >> "$WORK/r_id.http"; done

# ── 3) READ-BY-ID ───────────────────────────────────────────────────────────
sec "3/4  READ-BY-ID — GET /users/:id"
info "warming up (${WARMUP}s)…"; warm_http "$WORK/r_id.http"
info "measuring (${DURATION}s)…"
attack_http "$WORK/r_id.http" "$WORK/rid.bin"
record "READ   GET /users/:id" "$WORK/rid.bin"

# ── 4) READ-LIST ────────────────────────────────────────────────────────────
sec "4/4  READ-LIST — GET /users?limit=20"
printf 'GET %s/users?limit=20\n' "$BASE" > "$WORK/r_list.http"
info "warming up (${WARMUP}s)…"; warm_http "$WORK/r_list.http"
info "measuring (${DURATION}s)…"
attack_http "$WORK/r_list.http" "$WORK/rlist.bin"
record "READ   GET /users?limit=20" "$WORK/rlist.bin"

# ── Markdown report ─────────────────────────────────────────────────────────
# Rows and detail accumulate in sidecar files so the summary table stays
# CONSOLIDATED across backends (PERF_FRESH=1 truncates them). The report is
# reassembled whole each run: header → one table with every backend's rows →
# per-backend detail. A single-backend `bash qa/perf.sh` still yields a complete
# report; perf-all.sh drives both backends into the same table.
ROWS_F="${REPORT}.rows"; DETAIL_F="${REPORT}.detail"
if [ "$FRESH" = "1" ]; then : > "$ROWS_F"; : > "$DETAIL_F"; fi
printf '%s' "$ROWS" >> "$ROWS_F"
{
  echo
  echo "### CDC lag — ${BACKEND}"
  echo
  echo "> ${CDC_NOTE}"
  echo
  echo "### vegeta detail — ${BACKEND}"
  printf '%s\n' "$BLOCKS"
} >> "$DETAIL_F"
{
  echo "# Perf Report"
  echo
  echo "- **Generated:** $(date '+%Y-%m-%d %H:%M:%S')"
  echo "- **Load tool:** vegeta · open model · rate=${RATE}/s · duration=${DURATION}s · warmup=${WARMUP}s"
  echo "- **Bench:** single-instance docker-compose — numbers are RELATIVE (regression / PG-vs-MySQL), not capacity planning."
  echo "- **CQRS:** the READ scenarios hit the **Mongo projection**, not the relational backend — only **WRITE** and **CDC-lag** exercise PG/MySQL. Reads look alike across backends by design."
  echo
  echo "| Scenario | Backend | Rate/s | Reqs | Thr/s | p50 ms | p95 ms | p99 ms | Success | Status |"
  echo "|---|---|---:|---:|---:|---:|---:|---:|:---:|---|"
  cat "$ROWS_F"
  cat "$DETAIL_F"
} > "$REPORT"

sec "DONE — backend=$BACKEND"
info "Summary rows:"
printf '%s' "$ROWS"
info "CDC: ${CDC_NOTE}"
info "Full report appended to: $REPORT"
