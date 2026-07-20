#!/usr/bin/env bash
# HTTP server-hardening suite — the configurable transport knobs from item 2 of
# the production-readiness backlog: http.bodyLimitBytes, http.readTimeoutSeconds,
# http.idleTimeoutSeconds. The canonical example only ever exercises Fiber's
# DEFAULT 4MB BodyLimit (status_mapping.sh §3); this suite proves the knobs are
# honored at CONFIGURED values, at three distinct transport layers:
#
#   bodyLimitBytes (1 MB here)  → a 2 MB body — OVER the 1 MB knob but UNDER the
#       4 MB Fiber default, so a 413 can ONLY come from the configured knob —
#       returns 413 PayloadTooLargeNotification; a small body still passes (201).
#   readTimeoutSeconds (2s here)→ a slow client that dribbles its request body past
#       the deadline gets 408 ReadTimeoutNotification — a REAL enveloped response
#       (fasthttp maps the read-deadline net timeout to Fiber's ErrRequestTimeout,
#       which the framework ErrorHandler renders as 408). Distinct from the 504
#       app-deadline (http.requestTimeoutSeconds).
#   idleTimeoutSeconds (3s here)→ an idle keep-alive connection is CLOSED by the
#       server with NO response (a normal keep-alive teardown, not an error) — the
#       documented transport-level behavior.
#
# Boots the qa binary against a config DERIVED from microservice.qa.yaml with the
# three knobs injected under http:, via OMNICORE_CONFIG_PATH. Self-managed; qa
# binary. Dialect-driven via _backend.sh.
# Run from anywhere:  bash qa/http_hardening.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-hardening-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-hardening-${BACKEND:-postgres}.log"
HARDENING_YAML="/tmp/omnicore-qa-hardening-${BACKEND:-postgres}.yaml"
PROBE_HOST="localhost"; PROBE_PORT="${HTTP_PORT:-8080}"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port "${HTTP_PORT:-8080}"; rm -f "$HARDENING_YAML"
  qa_db_exec "DELETE FROM gadgets;" 2>/dev/null || true
  qa_view_drop gadgets gadget_notes
}
trap cleanup EXIT INT TERM

##############################################################################
sec "0. Derive low-limit config + build qa binary + boot"
##############################################################################
title "0.1 Derive $HARDENING_YAML from microservice.qa.yaml (inject http knobs)"
# Inject the three knobs right after the http.requestTimeoutSeconds line, keeping
# every other block (relational/mongo/transport/…) intact so the server boots.
BASE_YAML="$REPO_ROOT/microservice.qa.yaml" OUT_YAML="$HARDENING_YAML" python3 - <<'PY'
import os
src = open(os.environ["BASE_YAML"]).read().splitlines()
out = []
for line in src:
    out.append(line)
    if line.strip().startswith("requestTimeoutSeconds"):
        indent = line[:len(line) - len(line.lstrip())]
        out.append(f"{indent}bodyLimitBytes: 1048576      # 1 MB — well under Fiber's 4 MB default")
        out.append(f"{indent}readTimeoutSeconds: 2        # short transport read deadline (slowloris → 408)")
        out.append(f"{indent}idleTimeoutSeconds: 3        # short idle keep-alive close")
open(os.environ["OUT_YAML"], "w").write("\n".join(out) + "\n")
print("wrote", os.environ["OUT_YAML"])
PY
[ -f "$HARDENING_YAML" ] && ok "config derived" || { bad "config derivation failed"; exit 1; }

title "0.2 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"

title "0.3 Start server (config=$HARDENING_YAML)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$HARDENING_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }

##############################################################################
sec "1. bodyLimitBytes — the configured limit is enforced (not the 4MB default)"
##############################################################################
title "1.1 POST /qa/gadgets ~2MB body (over the 1MB knob, under the 4MB default) → 413"
# A 2 MB body would PASS under Fiber's 4 MB default; a 413 here can ONLY be the
# configured 1 MB knob. Expect: 100-continue lets the server answer 413 from the
# Content-Length before the upload, so curl reads the verdict instead of racing an
# oversized upload against an early close (retried to absorb that transport race).
BIG=$(mktemp)
{ printf '{"code":"BIG","name":"'; head -c 2000000 /dev/zero | tr '\0' 'A'; printf '","category":"c","status":"active"}'; } > "$BIG"
tmp=$(mktemp); st=""
for _try in 1 2 3; do
  st=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST "$BASE/qa/gadgets" \
    -H "Content-Type: application/json" -H "Expect: 100-continue" --expect100-timeout 5 \
    --data-binary @"$BIG") || true
  [ "$st" = "413" ] && break
  sleep 1
done
echo "POST ~2MB → $st  $(grep -o '"notificationKey":"[^"]*"' "$tmp" | head -1)"
if [ "$st" = "413" ] && grep -q '"notificationKey":"PayloadTooLargeNotification"' "$tmp"; then
  ok "1.1 body over the configured 1MB knob rejected (413 / PayloadTooLargeNotification)"
else
  bad "1.1 want 413 / PayloadTooLargeNotification, got $st"; head -c 200 "$tmp"; echo
fi
rm -f "$BIG" "$tmp"

title "1.2 POST /qa/gadgets small body (under 1MB) → 201 (knob doesn't reject normal bodies)"
tmp=$(mktemp)
st=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" \
  --data '{"code":"HARDEN-OK","name":"small","category":"c","status":"active"}') || true
echo "POST small → $st  $(head -c 120 "$tmp")"
if [ "$st" = "201" ]; then
  ok "1.2 a normal body under the limit is accepted (201)"
else
  bad "1.2 want 201 for a small body, got $st"; head -c 200 "$tmp"; echo
fi
rm -f "$tmp"

##############################################################################
sec "2. readTimeoutSeconds — a slow request body → 408 ReadTimeoutNotification"
##############################################################################
title "2.1 Dribble a request body past the 2s read deadline → 408"
# Raw socket: send the headers with a Content-Length promising more than we send,
# stall past readTimeout, then read the server's response. The framework renders
# the fasthttp read-deadline timeout as an enveloped 408 (distinct from a bare
# connection reset), so a compliant client actually RECEIVES the 408.
rt_out=$(PROBE_HOST="$PROBE_HOST" PROBE_PORT="$PROBE_PORT" python3 - <<'PY'
import os, socket, time
host, port = os.environ["PROBE_HOST"], int(os.environ["PROBE_PORT"])
headers = (
    "POST /qa/gadgets HTTP/1.1\r\n"
    f"Host: {host}:{port}\r\n"
    "Content-Type: application/json\r\n"
    "Content-Length: 2000\r\n\r\n"
)
resp = b""
try:
    s = socket.create_connection((host, port), timeout=15)
    s.sendall(headers.encode())
    s.sendall(b'{"code":"SLOW",')       # partial body, then simply stop sending
    # Do NOT send more: the server's read deadline fires at ~2s, emits the 408 and
    # closes (Connection: close). Just read — writing to the half-closed socket is
    # what would race an RST and discard the response. Tolerate a reset AFTER the
    # 408 bytes have landed.
    s.settimeout(8)                       # readTimeout is 2s — well within this
    while True:
        try:
            chunk = s.recv(4096)
        except (ConnectionResetError, OSError):
            break                          # RST after close — keep what we read
        if not chunk:
            break
        resp += chunk
    s.close()
except Exception as e:
    if not resp:
        print("PROBE-ERROR:", e)
if resp:
    print(resp.decode(errors="replace"))
PY
)
status_line=$(printf '%s\n' "$rt_out" | head -1)
echo "response status line: $status_line"
if printf '%s' "$rt_out" | grep -q "408 Request Timeout" && printf '%s' "$rt_out" | grep -q '"notificationKey":"ReadTimeoutNotification"'; then
  ok "2.1 slow request body → 408 ReadTimeoutNotification (enveloped, client received it)"
else
  bad "2.1 want a 408 ReadTimeoutNotification envelope"; printf '%s\n' "$rt_out" | head -c 400; echo
fi

##############################################################################
sec "3. idleTimeoutSeconds — an idle keep-alive connection is closed, no response"
##############################################################################
title "3.1 Hold a keep-alive idle past 3s → server closes it (EOF on reuse)"
# One request succeeds; then go idle past idleTimeout and try to reuse the SAME
# connection. The server has closed it — the reuse reads EOF (empty), which is the
# documented behavior: a silent keep-alive teardown, NOT an enveloped error.
idle_out=$(PROBE_HOST="$PROBE_HOST" PROBE_PORT="$PROBE_PORT" python3 - <<'PY'
import os, socket, time
host, port = os.environ["PROBE_HOST"], int(os.environ["PROBE_PORT"])
req = f"GET /livez HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n"
try:
    s = socket.create_connection((host, port), timeout=10)
    s.sendall(req.encode()); s.settimeout(6)
    r1 = s.recv(4096)
    if b"200 OK" not in r1:
        print("FIRST-REQUEST-FAILED"); raise SystemExit
    time.sleep(5)                          # idleTimeout is 3s
    try:
        s.sendall(req.encode()); s.settimeout(6)
        r2 = s.recv(4096)
        print("CLOSED" if not r2 else "STILL-OPEN")
    except OSError:
        print("CLOSED")                    # RST/broken pipe also = closed
    s.close()
except Exception as e:
    print("PROBE-ERROR:", e)
PY
)
echo "idle-reuse outcome: $idle_out"
if [ "$idle_out" = "CLOSED" ]; then
  ok "3.1 idle keep-alive connection closed by the server after idleTimeout (no response)"
else
  bad "3.1 want the idle connection CLOSED after 3s, got: $idle_out"
fi

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
