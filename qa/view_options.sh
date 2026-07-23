#!/usr/bin/env bash
# Read-side option suite — the ViewDefinition knobs the canonical example never
# opts into, on the qa-only Gadget mirror (`//go:build qa`):
#
#   MaxLimit(N)      — a per-view ?limit ceiling; ?limit>N is rejected (400)
#   RawDoc projector — the raw view document passes through (map[string]any)
#   DeleteOnArchive  — archived rows are DROPPED from the view (vs kept-hidden)
#
# Three views share the `gadgets` root: `gadgets` (default, keep-by-default),
# `gadgets_hot` (DeleteOnArchive), `gadgets_capped` (MaxLimit 5). All recompose
# on each gadgets CDC event.
#
# Self-managed; qa binary + microservice.qa.yaml + CDC. Dialect-driven.
# Run from anywhere:  bash qa/view_options.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-view-options-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-view-options-${BACKEND:-postgres}.log"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port "${HTTP_PORT:-8080}"
  qa_db_exec "DELETE FROM gadgets;" 2>/dev/null || true
  qa_view_drop gadgets gadget_notes gadgets_hot gadgets_capped upstream_gadgets
}
trap cleanup EXIT INT TERM

# list_count <path-with-query> → data length (or -1)
list_count() {
  curl -sS "$BASE$1" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); data=d.get("data",[])
  print(len(data) if isinstance(data,list) else -1)
except Exception: print(-1)' 2>/dev/null
}

##############################################################################
sec "0. Build qa binary + boot + seed"
##############################################################################
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$REPO_ROOT/microservice.qa.yaml" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }

# Prove the CDC pipeline is hot (consumer groups joined, Debezium task live)
# BEFORE any per-step deadline starts counting; the clean-baseline step below
# sweeps the sentinel. Non-fatal — see qa/_backend.sh.
qa_cdc_warmup_gadget

title "0.1 Reset + seed 8 gadgets (enough to overflow the MaxLimit(5) cap)"
qa_db_exec "DELETE FROM gadgets;"
qa_view_drop gadgets gadget_notes gadgets_hot gadgets_capped upstream_gadgets
sleep 1
# Each POST is verified (201) and retried — a transient write failure would
# otherwise surface later as a misleading CDC timeout. The materialization
# deadline is 90s: inside the full run.sh matrix the connector may still be
# draining the CDC backlog left by the preceding suites.
for i in 1 2 3 4 5 6 7 8; do
  st=""
  for _try in 1 2 3; do
    st=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" \
      --data "{\"code\":\"RX-$i\",\"name\":\"Read Extra $i\",\"category\":\"rx\",\"status\":\"active\"}")
    [ "$st" = "201" ] && break
    sleep 1
  done
  [ "$st" = "201" ] || echo "WARN: seed POST RX-$i returned $st after 3 attempts"
done
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); seeded=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ "$(list_count "/qa/gadgets?code.startswith=RX")" = "8" ] && { seeded=ok; break; }
  sleep 1
done
[ "$seeded" = ok ] && ok "8 gadgets materialized in the default view" || { bad "seed did not reach 8"; }

##############################################################################
sec "1. MaxLimit(5) — per-view ?limit ceiling"
##############################################################################
title "1.1 GET /qa/gadgets-capped?limit=100 → 400 LimitExceededNotification"
tmp=$(mktemp); st=$(curl -sS -o "$tmp" -w "%{http_code}" "$BASE/qa/gadgets-capped?limit=100")
if [ "$st" = "400" ] && grep -q '"notificationKey":"LimitExceededNotification"' "$tmp"; then
  ok "?limit>5 rejected (400 / LimitExceededNotification)"
else bad "want 400/LimitExceededNotification, got $st"; head -c 200 "$tmp"; echo; fi
rm -f "$tmp"

title "1.2 GET /qa/gadgets-capped?limit=5 → 200 (at the cap)"
st=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/qa/gadgets-capped?limit=5")
[ "$st" = "200" ] && ok "?limit=5 accepted (200)" || bad "?limit=5 status $st (want 200)"

title "1.3 The default gadgets view accepts ?limit=100 (framework default 100, no per-view cap)"
st=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/qa/gadgets?limit=100")
[ "$st" = "200" ] && ok "default view ?limit=100 accepted" || bad "default ?limit=100 status $st"

##############################################################################
sec "2. RawDoc projector — raw view document passthrough"
##############################################################################
title "2.1 GET /qa/gadgets-raw → raw docs keyed by Go field names (NOT the json wire names)"
# The RawDoc projector passes the reader's doc through verbatim, so the keys are
# the Go field names the reader translated the physical columns into (Code, Name,
# _id) — NOT the json wire names (code, name) a typed Response would emit. That
# divergence IS the point: proving RawDoc bypasses the per-Response json mapping.
RAW=$(curl -sS "$BASE/qa/gadgets-raw?code.startswith=RX&limit=3")
echo "$RAW" | python3 -m json.tool 2>/dev/null | head -16
HASRAW=$(echo "$RAW" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); items=d.get("data",[])
  # raw passthrough → Go names present (Code/_id), json wire name (code) absent
  print("y" if items and any(("Code" in x or "_id" in x) and "code" not in x for x in items) else "n")
except Exception: print("n")' 2>/dev/null)
[ "$HASRAW" = y ] && ok "raw docs pass through Go-named keys (Code/_id), not the json wire names" || bad "raw projector did not return the expected raw doc shape"
# Contrast: the typed /qa/gadgets list emits the json wire name (lowercase code).
TYPED=$(curl -sS "$BASE/qa/gadgets?code.eq=RX-1" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); items=d.get("data",[]); print("y" if items and "code" in items[0] else "n")
except Exception: print("n")' 2>/dev/null)
[ "$TYPED" = y ] && ok "typed view emits the json wire name (lowercase code) — the projector difference is real" || bad "typed view shape unexpected"

##############################################################################
sec "3. DeleteOnArchive — archived rows DROP from gadgets_hot, KEPT in gadgets"
##############################################################################
title "3.0 Pick a gadget id + confirm it is in BOTH gadgets and gadgets_hot"
GID=$(curl -sS "$BASE/qa/gadgets?code.eq=RX-1" | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(d[0]["id"] if d else "")')
echo "GID=$GID"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); inhot=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ "$(list_count "/qa/gadgets-hot?code.eq=RX-1")" = "1" ] && { inhot=ok; break; }
  sleep 1
done
[ "$inhot" = ok ] && ok "RX-1 present in gadgets_hot before archive" || bad "RX-1 not in gadgets_hot"

title "3.1 Archive RX-1"
st=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH "$BASE/qa/gadgets/$GID/archive")
[ "$st" = "200" ] && ok "archive accepted (200)" || bad "archive status $st"

title "3.2 gadgets_hot DROPS the archived row (even with ?includeArchived=true)"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); dropped=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ "$(list_count "/qa/gadgets-hot?code.eq=RX-1&includeArchived=true")" = "0" ] && { dropped=ok; break; }
  sleep 1
done
[ "$dropped" = ok ] && ok "RX-1 dropped from gadgets_hot (DeleteOnArchive)" || bad "RX-1 still in gadgets_hot after archive"

title "3.2b DeleteOnArchive records a document tombstone in the projection-state registry"
# New in 0.36.0: an ARCHIVED removal under DeleteOnArchive follows the same
# tombstone discipline as DELETED — the registry records doc:<view>:<id> with
# the event's revision, so a zombie consumer's older upsert can never
# resurrect the removed document. (§3.4's unarchive below then proves a
# FRESHER event re-materializes it past the tombstone.)
TOMB=$(docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval \
  "var d=db.omnicore_projection_state.findOne({_id:'doc:gadgets_hot:$GID'}); print(d?Number(d.revision):-1)" 2>/dev/null | tail -1 | tr -d '[:space:]')
if [ "${TOMB:--1}" -ge 1 ] 2>/dev/null; then
  ok "tombstone doc:gadgets_hot:<id> recorded (revision $TOMB)"
else bad "no tombstone for the DeleteOnArchive removal (got $TOMB)"; fi

title "3.3 default gadgets KEEPS it (hidden by default, visible via ?includeArchived=true)"
DEF_DEFAULT=$(list_count "/qa/gadgets?code.eq=RX-1")
DEF_ARCH=$(list_count "/qa/gadgets?code.eq=RX-1&includeArchived=true")
[ "$DEF_DEFAULT" = "0" ] && ok "default view hides the archived RX-1 by default" || bad "default view still shows RX-1 (count=$DEF_DEFAULT)"
[ "$DEF_ARCH" = "1" ] && ok "default view surfaces RX-1 with ?includeArchived=true (kept, not dropped)" || bad "?includeArchived did not surface RX-1 (count=$DEF_ARCH)"

title "3.4 UNARCHIVE round-trip — RX-1 re-materializes in the DeleteOnArchive view"
# Coverage audit 2026-07-21: §3 only proved the archive side of DeleteOnArchive.
# The UNARCHIVED event must re-materialize the doc in gadgets_hot (the hot tier
# converges back) and flip it visible-by-default in the kept view.
st=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH "$BASE/qa/gadgets/$GID/unarchive")
[ "$st" = "200" ] && ok "unarchive accepted (200)" || bad "unarchive status $st"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); back=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ "$(list_count "/qa/gadgets-hot?code.eq=RX-1")" = "1" ] && { back=ok; break; }
  sleep 1
done
[ "$back" = "ok" ] && ok "gadgets_hot re-materialized RX-1 after unarchive" || bad "RX-1 never returned to gadgets_hot"
[ "$(list_count "/qa/gadgets?code.eq=RX-1")" = "1" ] && ok "default view shows RX-1 again without ?includeArchived" || bad "default view still hides unarchived RX-1"

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
