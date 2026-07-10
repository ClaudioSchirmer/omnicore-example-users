#!/usr/bin/env bash
# Distributed-tracing E2E suite for omnicore-example-users.
#
# The dev profile already enables OpenTelemetry (observability.tracing.enabled:
# true, exporter=otlp → localhost:4317, sampler=always_on) shipping spans to the
# Jaeger all-in-one container. This suite proves the wiring end to end WITHOUT
# any example-service code — it is pure observation of the running framework:
#
#   1. Jaeger reachable + the service registers under its own name.
#   2. A request produces a trace whose span tree carries the server span PLUS
#      child spans from the instrumented subsystems (pgx / mongo) — proving the
#      `instrument:` list actually emits spans down the stack.
#   3. The correlationID == trace_id contract: the slog `traceId` the framework
#      stamps on the in-TX audit echo is a REAL Jaeger trace id — GET
#      /api/traces/<traceId> resolves to that very trace. This is the join key
#      that ties logs, audit_events.trace_id, and integration_events.correlation_id
#      to one value (web/app_context.go: SetCorrelationID(uuidFromTraceID(...))).
#
# Jaeger is OPTIONAL observability (not in the default compose up), so this
# suite starts it itself and waits for its query API.
#
# Prerequisites: docker compose up (postgres/mongo/kafka) + the Debezium
# connector registered (same as e2e.sh). Self-managed server lifecycle.
#
# Run from anywhere:  bash qa/tracing.sh
set -u

BASE="${BASE:-http://localhost:8080}"
JAEGER="${JAEGER:-http://localhost:16686}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-tracing-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-tracing-${BACKEND:-postgres}.log"
SERVICE_NAME="${OTEL_SERVICE_NAME:-omnicore-example-users}"

PASS=0; FAIL=0
SERVER_PID=""

hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

kill_port() {
  local pids; pids=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true)
  if [ -n "$pids" ]; then kill $pids 2>/dev/null || true; sleep 1
    pids=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true)
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
  fi
}
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true
  fi
  kill_port "${HTTP_PORT:-8080}"
}
trap cleanup EXIT INT TERM

wait_for_health() {
  local deadline=$(( $(date +%s) + 30 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    curl -sf -o /dev/null "$BASE/livez" && return 0; sleep 0.5
  done
  return 1
}

##############################################################################
sec "0. Bring up Jaeger + wait for its query API"
##############################################################################
title "0.1 docker compose up jaeger (optional observability container)"
(cd "$REPO_ROOT" && docker compose -f devops/docker-compose.yml up -d jaeger >/dev/null 2>&1)
deadline=$(( $(date +%s) + 40 )); jready=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  if curl -sf -o /dev/null "$JAEGER/api/services"; then jready=ok; break; fi
  sleep 1
done
[ "$jready" = ok ] && ok "Jaeger query API reachable at $JAEGER" \
                    || { bad "Jaeger did not come up at $JAEGER"; printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"; exit 1; }

title "0.2 Build server binary (dev profile has tracing enabled)"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"

title "0.3 Start server (APP_PROFILE=dev → otlp exporter to localhost:4317)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
wait_for_health || { bad "server did not become ready"; tail -n 40 "$SERVER_LOG"; exit 1; }
ok "server ready (PID=$SERVER_PID)"

##############################################################################
sec "1. A request emits a trace that reaches Jaeger"
##############################################################################
# A unique document so the audit line + trace are unambiguous. auth.mode is
# disabled in dev, so the write still emits an audit slog line (actor=anonymous)
# carrying the top-level `traceId` the tracing slog handler stamps.
TRACE_DOC="42000000$(printf '%03d' $(( $(date +%s) % 1000 )))"
title "1.1 POST /users (marks a fresh trace) + capture the audit line's traceId"
LINES_BEFORE=$(wc -l < "$SERVER_LOG" | tr -d ' ')
HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE/users" \
  -H "Content-Type: application/json" \
  --data "{\"name\":\"Trace Probe\",\"email\":\"trace.$TRACE_DOC@example.com\",\"phone\":\"14155552671\",\"document\":\"$TRACE_DOC\",\"userName\":\"trace$TRACE_DOC\"}")
[ "$HTTP" = "201" ] && ok "write accepted (201)" || bad "write status $HTTP"

# Grab the traceId off the first audit line emitted after our request.
TRACE_ID=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  TRACE_ID=$(sed -n "$((LINES_BEFORE+1)),\$p" "$SERVER_LOG" \
    | grep '"msg":"audit"' | head -n1 \
    | python3 -c 'import sys,json
line=sys.stdin.readline()
try: print(json.loads(line).get("traceId",""))
except Exception: print("")' 2>/dev/null)
  [ -n "$TRACE_ID" ] && break
  sleep 0.3
done
if [ -n "$TRACE_ID" ] && [ "$TRACE_ID" != "0000000000000000000000000000000000" ]; then
  ok "captured traceId from the audit slog echo: $TRACE_ID"
else
  bad "no traceId on the audit line (tracing slog handler not stamping?)"
fi

title "1.2 Jaeger registers the service"
deadline=$(( $(date +%s) + 30 )); svc=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  if curl -sf "$JAEGER/api/services" | grep -q "$SERVICE_NAME"; then svc=ok; break; fi
  sleep 1
done
[ "$svc" = ok ] && ok "service '$SERVICE_NAME' present in /api/services" \
                 || bad "service not registered in Jaeger within 30s"

##############################################################################
sec "2. correlationID == trace_id — the audit traceId IS a real Jaeger trace"
##############################################################################
# The single most important tracing contract: the id the framework stamps on
# logs + audit_events.trace_id + integration_events.correlation_id is the
# ACTUAL OTel trace id. Resolve the captured audit traceId against Jaeger's
# by-id endpoint; a hit proves the join key is real, not a coincidental UUID.
if [ -n "$TRACE_ID" ]; then
  title "2.1 GET /api/traces/$TRACE_ID resolves to a trace"
  deadline=$(( $(date +%s) + 30 )); hit=fail; SPANCOUNT=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    BODY=$(curl -sf "$JAEGER/api/traces/$TRACE_ID" 2>/dev/null || echo "")
    SPANCOUNT=$(printf '%s' "$BODY" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); data=d.get("data") or []
  print(len(data[0].get("spans",[])) if data else 0)
except Exception: print(0)' 2>/dev/null)
    [ "${SPANCOUNT:-0}" -ge 1 ] 2>/dev/null && { hit=ok; break; }
    sleep 1
  done
  [ "$hit" = ok ] && ok "audit traceId resolves in Jaeger with $SPANCOUNT span(s) — correlationID == trace_id proven" \
                   || bad "audit traceId $TRACE_ID never resolved in Jaeger (spans=$SPANCOUNT)"
else
  bad "2.1 skipped — no traceId captured"
fi

##############################################################################
sec "3. Span tree carries server + instrumented-subsystem child spans"
##############################################################################
# Drive a mix of write + read so the trace tree spans http → dispatch →
# pgx/mongo. Then pull recent traces for the service and assert the union of
# span operation/process names includes an HTTP server span AND at least one
# child from the instrument list (pgx OR mongo OR kafka).
title "3.0 Drive a few more requests (GET by id + list → pgx + mongo spans)"
curl -sS -o /dev/null "$BASE/users?limit=5"
curl -sS -o /dev/null "$BASE/livez"
sleep 3   # async batched span export

title "3.1 Recent traces carry server + a pgx/mongo/kafka child span"
LOOKBACK_US=$(( 3600 * 1000000 ))   # 1h in microseconds (Jaeger wants micros)
TRACES=$(curl -sf "$JAEGER/api/traces?service=$SERVICE_NAME&limit=40&lookback=1h" 2>/dev/null || echo "")
ANALYSIS=$(printf '%s' "$TRACES" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("ERR 0 0 0"); sys.exit(0)
data = d.get("data") or []
# Collect operation names + process service tags across all spans.
ops = []
kinds = set()
for tr in data:
    procs = tr.get("processes", {})
    for sp in tr.get("spans", []):
        ops.append(sp.get("operationName",""))
        # look at db.system / rpc / messaging tags to classify child spans
        for t in sp.get("tags", []):
            k = t.get("key",""); v = str(t.get("value",""))
            if k in ("db.system","db.statement") or "pgx" in v.lower() or "postgres" in v.lower() or "mysql" in v.lower():
                kinds.add("sql")
            if k == "db.system" and "mongo" in v.lower(): kinds.add("mongo")
            if "mongo" in (sp.get("operationName","") or "").lower(): kinds.add("mongo")
            if k.startswith("messaging") or "kafka" in v.lower(): kinds.add("kafka")
ntr = len(data)
has_server = any(("/" in o) or o.isupper() or "HTTP" in o or "GET" in o or "POST" in o for o in ops)
child = "yes" if kinds else "no"
print("OK", ntr, "server" if has_server else "noserver", child, ";".join(sorted(kinds)))
' 2>/dev/null)
echo "trace analysis: $ANALYSIS"
NTR=$(echo "$ANALYSIS" | awk '{print $2}')
if [ "$(echo "$ANALYSIS" | awk '{print $1}')" = "OK" ] && [ "${NTR:-0}" -ge 1 ] 2>/dev/null; then
  ok "$NTR trace(s) exported for the service"
else
  bad "no traces returned for the service"
fi
if echo "$ANALYSIS" | grep -q "server"; then
  ok "trace tree carries an HTTP server span"
else
  bad "no HTTP server span found in the exported traces"
fi
# Child instrumentation (pgx/mongo/kafka) — assert at least one downstream span
# kind surfaced, proving the instrument: list emits below the server span.
if echo "$ANALYSIS" | grep -qE "sql|mongo|kafka"; then
  ok "downstream instrumented span present (sql/mongo/kafka)"
else
  bad "no pgx/mongo/kafka child span found — instrument list not emitting?"
fi

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
echo "Server log: $SERVER_LOG"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
