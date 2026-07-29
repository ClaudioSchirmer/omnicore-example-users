#!/usr/bin/env bash
# Ripple-leg resilience suite — the unified failure ledger's kind='ripple' half,
# proven end to end at runtime on the qa_lens_* JoinView family (see
# view_embed.sh for the family's happy-path contract):
#
#   §1  a brand rename whose EMBED-LEG write is blocked (a Mongo collection
#       validator on the embedder — real fault injection, no code stubs) parks
#       a kind='ripple' row in omnicore_projection_failures (asserted via SQL:
#       source `view:qa_lens_brands_view`, dependent view, stage) while the
#       brand's OWN document updates fine — failure isolation intact;
#   §2  after the fault is removed, the parkedRetry loop (pinned to 1 minute
#       via a derived yaml) replays the pair from CURRENT state with no manual
#       action: the segment heals, the row resolves, and the CHAIN resumes —
#       the kit's second-hop copy (kits[].parts[].brand) converges too;
#   §3  the structured trail: the ripple failure log + the replay log.
#
# This is the runtime twin of projection_resilience.sh (which proves the
# kind='event' half). Parallel-safe: the validator touches only this lane's own
# view DB and the fixture family is suite-owned.
#
# Prereqs: docker compose up + the OUTBOX Debezium connector registered.
# Self-managed server lifecycle. Dialect-driven via qa/_backend.sh.
# Run from anywhere:  bash qa/projection_ripple.sh
set -u

BASE="${BASE:-http://localhost:8080}"
HTTP_PORT="${HTTP_PORT:-8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-projripple-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-projripple-${BACKEND:-postgres}.log"
DERIVED_YAML="/tmp/omnicore-example-users-qa-projripple-${BACKEND:-postgres}.yaml"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }

jid()  { python3 -c 'import sys,json
d=json.load(sys.stdin)
print(d.get("data",{}).get("id",""))'; }
post_json() { curl -sS -X POST "$1" -H "Content-Type: application/json" --data "$2"; }
put_json()  { curl -sS -X PUT  "$1" -H "Content-Type: application/json" --data "$2"; }
jpath() {
  curl -sS "$1" | python3 -c "
import sys, json
d = json.load(sys.stdin).get('data', {})
for seg in '$2'.split('.'):
    if isinstance(d, list):
        d = d[int(seg)] if len(d) > int(seg) else {}
    else:
        d = d.get(seg) if isinstance(d, dict) else None
    if d is None:
        break
print(d if d is not None else '')"
}
wait_for() {
  local url="$1" path="$2" want="$3" tries="${4:-40}" got=""
  for _ in $(seq 1 "$tries"); do
    got=$(jpath "$url" "$path")
    [ "$got" = "$want" ] && return 0
    sleep 0.5
  done
  printf '  (last seen: %s want: %s)\n' "${got:-<empty>}" "$want"
  return 1
}

# Ledger probes — the unified table, ripple half, via the lane's SQL seam.
ripple_pending()  { qa_db_query "SELECT COUNT(*) FROM omnicore_projection_failures WHERE kind='ripple' AND topic='view:qa_lens_brands_view' AND resolved_at IS NULL" | tr -dc '0-9'; }
ripple_resolved() { qa_db_query "SELECT COUNT(*) FROM omnicore_projection_failures WHERE kind='ripple' AND topic='view:qa_lens_brands_view' AND resolved_at IS NOT NULL" | tr -dc '0-9'; }
wait_eq() {
  local want="$1" secs="$2"; shift 2
  local deadline=$(( $(date +%s) + secs )) got=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    got=$("$@" 2>/dev/null)
    [ "$got" = "$want" ] && return 0
    sleep 1
  done
  echo "want='$want' got='$got'" >&2
  return 1
}

# Fault injection: a query-style collection VALIDATOR on the embedder's ACTIVE
# slot that rejects any document whose brand segment carries the forbidden
# name. The ripple's surgical update then fails with DocumentValidationFailure
# — a real Mongo write error on exactly one leg, nothing stubbed.
PARTS_COLL=""
install_validator() {
  PARTS_COLL=$(qa_view_coll qa_lens_parts_view)
  docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval \
    "db.runCommand({collMod: '$PARTS_COLL', validator: {'brand.name': {\$ne: 'FORBIDDEN'}}, validationLevel: 'strict'})" >/dev/null
}
remove_validator() {
  [ -n "$PARTS_COLL" ] && docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval \
    "db.runCommand({collMod: '$PARTS_COLL', validator: {}, validationLevel: 'off'})" >/dev/null 2>&1 || true
}

drop_collections() { qa_view_drop qa_lens_parts_view qa_lens_kits_view qa_lens_kits_desc_view qa_lens_brands_view; }
reset_domain() {
  qa_db_exec "DELETE FROM qa_lens_parts;" 2>/dev/null || true
  qa_db_exec "DELETE FROM qa_lens_kits;"  2>/dev/null || true
  qa_db_exec "DELETE FROM qa_lens_brands;" 2>/dev/null || true
  qa_db_exec "DELETE FROM omnicore_projection_failures WHERE kind='ripple' AND topic LIKE 'view:qa_lens%';" 2>/dev/null || true
  drop_collections
}
cleanup() {
  remove_validator
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port "$HTTP_PORT"
  reset_domain
}
trap cleanup EXIT INT TERM

##############################################################################
sec "0. Build qa binary + derived yaml (parkedRetry: 1min) + boot"
##############################################################################
reset_domain
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
# The framework default is 10 minutes — right for production, unobservable for
# a test. Pin 1 minute, same rationale as dev.yaml's pin.
sed 's|^  database:\(.*\)$|  database:\1\n  parkedRetry:\n    intervalMinutes: 1|' \
  "$REPO_ROOT/microservice.qa.yaml" > "$DERIVED_YAML"
grep -q "parkedRetry:" "$DERIVED_YAML" || { bad "derived yaml missing parkedRetry"; exit 1; }
kill_port "$HTTP_PORT"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$DERIVED_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 40 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready (parkedRetry pinned to 1min)" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }

title "0.1 Fixture: brand + kit + part, composed through CDC"
BRAND=$(post_json "$BASE/qa/lens-brands" '{"name":"Zeiss"}' | jid)
KIT=$(post_json "$BASE/qa/lens-kits" '{"name":"Alpha kit"}' | jid)
P1=$(post_json "$BASE/qa/lens-parts" "{\"kitId\":\"$KIT\",\"gadgetId\":null,\"brandId\":\"$BRAND\",\"label\":\"left lens\",\"slot\":1}" | jid)
[ -n "$BRAND" ] && [ -n "$KIT" ] && [ -n "$P1" ] && ok "fixture created (brand=$BRAND part=$P1)" || { bad "fixture creation failed"; exit 1; }
wait_for "$BASE/qa/lens-parts/$P1" "brand.name" "Zeiss" 120 && ok "part composed with the brand segment" || bad "brand segment never composed"
wait_for "$BASE/qa/lens-kits/$KIT" "parts.0.brand.name" "Zeiss" 60 && ok "kit composed with the second-hop copy" || bad "second hop never composed"

##############################################################################
sec "1. The leg fails: a blocked segment write parks a kind='ripple' row"
##############################################################################
title "1.1 Install the validator on the embedder's active slot ($(qa_view_coll qa_lens_parts_view))"
install_validator && ok "validator installed" || bad "validator install failed"

title "1.2 Rename the brand to the forbidden value — its OWN document updates, the leg fails"
put_json "$BASE/qa/lens-brands/$BRAND" '{"name":"FORBIDDEN"}' >/dev/null
# The brands surface is list-only and filters on `name` only — the renamed
# value showing up in a name-filtered listing IS the proof its own doc updated.
wait_for "$BASE/qa/lens-brands?name=FORBIDDEN" "0.name" "FORBIDDEN" 60 && ok "the brand's own view updated (failure isolation)" || bad "the brand's own view never updated"

title "1.3 The unified ledger gains the pending pair (via SQL)"
wait_eq 1 60 ripple_pending && ok "kind='ripple' row parked for (view:qa_lens_brands_view → qa_lens_parts_view)" || bad "no ripple row appeared"
ROW=$(qa_db_query "SELECT stage FROM omnicore_projection_failures WHERE kind='ripple' AND topic='view:qa_lens_brands_view' AND resolved_at IS NULL" | tr -d '[:space:]')
[ "$ROW" = "upsert" ] && ok "stage records WHERE it failed (upsert)" || bad "unexpected stage: '$ROW'"

title "1.4 The stale segment is really stale (the row is not a false alarm)"
GOT=$(jpath "$BASE/qa/lens-parts/$P1" "brand.name")
[ "$GOT" = "Zeiss" ] && ok "part still carries the old name — the leg genuinely failed" || bad "part shows '$GOT'"

##############################################################################
sec "2. The fault heals: the parkedRetry loop replays the pair, the chain resumes"
##############################################################################
title "2.1 Remove the validator"
remove_validator && ok "validator removed" || bad "validator removal failed"

title "2.2 The sweep replays with no manual action (≤ ~2 intervals)"
wait_for "$BASE/qa/lens-parts/$P1" "brand.name" "FORBIDDEN" 300 && ok "segment healed by the ledger replay" || bad "segment never healed"
wait_eq 0 30 ripple_pending && ok "pending row drained" || bad "row still pending"
RES=$(ripple_resolved)
[ "${RES:-0}" -ge 1 ] && ok "row marked resolved (audit trail kept)" || bad "no resolved row"

title "2.3 The CHAIN resumed: the second hop converged too"
wait_for "$BASE/qa/lens-kits/$KIT" "parts.0.brand.name" "FORBIDDEN" 120 && ok "kit's parts[].brand caught up (hop 2 after the replay)" || bad "second hop never converged"

##############################################################################
sec "3. The structured trail"
##############################################################################
if grep -q '"msg":"upstream.recompose.upsert"' "$SERVER_LOG"; then
  ok "the leg failure was logged with its coordinate"
else
  bad "no upstream.recompose.upsert in the server log"
fi
grep -q '"msg":"projection.parked_ripple.replaying"' "$SERVER_LOG" && ok "the replay left its structured trace" || bad "no parked_ripple.replaying in the log"

hr
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
