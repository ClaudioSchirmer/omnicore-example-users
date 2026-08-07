#!/usr/bin/env bash
# LinkInChild suite — the READ-TIME twin of EmbedInChild on a ComposedView.
#
# qa_catalog_full is a ComposedView whose PRIMARY is the materialized
# qa_catalog_view (a normal view whose CatalogLines carry a materialized
# EmbedInChild "item"). It adds a LinkInChild that enriches each CatalogLine
# element with "liveItem" — the SAME upstream item, joined by the line's own
# item_id at READ time, never materialized. So each line ends up carrying BOTH
# "item" (materialized) and "liveItem" (read-time) — proving read-time
# equivalence.
#
# Asserts:
#   (1) compose — every line's liveItem resolves to its upstream item; a
#       null-FK line gets a null liveItem (LEFT semantics per element);
#   (2) equivalence — liveItem labels == the materialized item labels;
#   (3) segment filter — ?catalogLines.liveItem.label=X attaches liveItem only
#       to matching lines, nulls the rest, and NEVER drops lines or primary rows;
#   (4) ?fields= into the in-child segment prunes to the enrichment;
#   (5) sort into a segment → 400 (order is the primary's);
#   (6) read-time ripple — renaming the item updates liveItem on the next read,
#       the composed document never materialized;
#   (7) CSV export walks the liveItem branch.
#
# Uses the qa binary + microservice.qa.yaml. Self-managed server. Dialect-driven.
# Prereqs: docker compose up + the OUTBOX Debezium connector registered.
# Run from anywhere:  bash qa/link_in_child.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-link-in-child-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-link-in-child-${BACKEND:-postgres}.log"
QA_YAML="$REPO_ROOT/microservice.qa.yaml"
GET_TMP="/tmp/qa-lic-get.json.${BACKEND:-default}"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
drop_collections() { qa_view_drop qa_catalog_view upstream_items; }
reset_domain() {
  qa_db_exec "DELETE FROM qa_items;" 2>/dev/null || true
  qa_db_exec "DELETE FROM qa_catalog_lines;" 2>/dev/null || true
  qa_db_exec "DELETE FROM qa_catalogs;" 2>/dev/null || true
  drop_collections
}
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port "${HTTP_PORT:-8080}"
  reset_domain
  rm -f "$GET_TMP"
}
trap cleanup EXIT INT TERM

# ── JSON helpers ─────────────────────────────────────────────────────────────
jid() { python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("data",{}).get("id",""))
except Exception: print("")'; }
post_json() { curl -sS -X POST "$1" -H "Content-Type: application/json" --data "$2"; }
new_item()  { post_json "$BASE/qa/items" "$1" | jid; }
# jchild URL CHILD_SEG ENRICH -> sorted labels of data.<child>[].<enrich>.label
# (empty label "" for a line whose enrichment is null).
jchild() {
  curl -sS -o "$GET_TMP" "$1"
  python3 -c '
import sys, json
try: d = json.load(open(sys.argv[1]))
except Exception: print(""); sys.exit()
arr = (d.get("data") or {}).get(sys.argv[2]) or []
out=[]
for x in arr:
    seg = x.get(sys.argv[3]) if isinstance(x, dict) else None
    out.append(seg.get("label","") if isinstance(seg, dict) else "")
print(",".join(sorted(out)))' "$GET_TMP" "$2" "$3"
}
# jchild_url same as jchild but reads a URL already fetched into GET_TMP
jchild_file() {
  python3 -c '
import sys, json
try: d = json.load(open(sys.argv[1]))
except Exception: print(""); sys.exit()
arr = (d.get("data") or (d.get("data") if isinstance(d.get("data"),dict) else {})) or {}
# list endpoint: data[0]; by-id: data
node = d.get("data")
if isinstance(node, list): node = node[0] if node else {}
arr = (node or {}).get(sys.argv[2]) or []
out=[]
for x in arr:
    seg = x.get(sys.argv[3]) if isinstance(x, dict) else None
    out.append(seg.get("label","") if isinstance(seg, dict) else "")
print(",".join(sorted(out)))' "$GET_TMP" "$2" "$3"
}
wait_child() { # URL CHILD_SEG ENRICH EXPECTED_CSV
  local deadline=$(( $(date +%s) + QA_CDC_DEADLINE )) got=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    got=$(jchild "$1" "$2" "$3"); [ "$got" = "$4" ] && return 0; sleep 1
  done
  echo "    (last seen: '$got', wanted: '$4')" >&2; return 1
}
lget() { local url="$1"; shift; local a=(); local kv; for kv in "$@"; do a+=(--data-urlencode "$kv"); done; curl -sS -G -o "$GET_TMP" "$url" ${a[@]+"${a[@]}"}; }
http_code() { local url="$1"; shift; local a=(); local kv; for kv in "$@"; do a+=(--data-urlencode "$kv"); done; curl -sS -G -o /dev/null -w '%{http_code}' "$url" ${a[@]+"${a[@]}"}; }
lcount() { python3 -c 'import sys,json;d=json.load(open(sys.argv[1])).get("data");print(len(d) if isinstance(d,list) else (1 if d else 0))' "$GET_TMP"; }
# nlines FILE CHILD_SEG — number of child elements on data[0]/data
nlines() { python3 -c '
import sys,json
d=json.load(open(sys.argv[1])).get("data")
if isinstance(d,list): d=d[0] if d else {}
print(len((d or {}).get(sys.argv[2]) or []))' "$GET_TMP" "$2"; }
# haskey_count FILE CHILD_SEG KEY — how many child elements carry KEY (present on the wire)
haskey_count() { python3 -c '
import sys,json
d=json.load(open(sys.argv[1])).get("data")
if isinstance(d,list): d=d[0] if d else {}
arr=(d or {}).get(sys.argv[2]) or []
print(sum(1 for x in arr if isinstance(x,dict) and sys.argv[3] in x))' "$GET_TMP" "$2" "$3"; }

##############################################################################
sec "0. Build qa binary + ensure outbox connector + boot with qa.yaml"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"

title "0.2 Ensure the outbox Debezium connector is registered"
"$REPO_ROOT/devops/debezium/register-connector.sh" "$QA_CONNECTOR_DIALECT" >/dev/null 2>&1 && ok "outbox connector registered" || bad "outbox connector registration failed"

title "0.3 Start server (APP_PROFILE=dev, config=microservice.qa.yaml)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$QA_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready" || { bad "server not ready"; tail -n 40 "$SERVER_LOG"; exit 1; }

qa_cdc_warmup_gadget
title "0.4 Clean baseline"
reset_domain
sleep 1
ok "clean baseline"

##############################################################################
sec "1. Seed a catalog with lines + upstream items; wait for the primary"
##############################################################################
# Two upstream items the lines point at, plus one line with NO itemId.
L1_ID=$(new_item '{"label":"C1"}')
L2_ID=$(new_item '{"label":"C2"}')
CAT_ID=$(post_json "$BASE/qa/catalogs" "{\"name\":\"LIC Collection\",\"lines\":[{\"itemId\":\"$L1_ID\",\"note\":\"line-1\"},{\"itemId\":\"$L2_ID\",\"note\":\"line-2\"},{\"note\":\"line-null\"}]}" | jid)
[ -n "$CAT_ID" ] && ok "seeded catalog $CAT_ID with 3 lines (2 with itemId, 1 null)" || { bad "catalog seed failed"; tail -n 30 "$SERVER_LOG"; exit 1; }

CAT_FULL_URL="$BASE/qa/catalogs-full/$CAT_ID"

# Deliberately NOT gated on the primary's materialized EmbedInChild "item": that
# is a SEPARATE mechanism (a recompose-ripple that reverse-scans the catalog on
# catalogLines.item_id) with its own timing. LinkInChild reads upstream_items at
# request time, so it depends only on the LINES being materialized (the catalog's
# own CDC) and upstream_items being materialized (the item's CDC) — never on the
# EmbedInChild ripple. So we wait on liveItem itself.

##############################################################################
sec "2. Compose: liveItem is computed per child element at read time"
##############################################################################
title "2.1 Every line gains a read-time liveItem; null-FK line → null"
wait_child "$CAT_FULL_URL" "catalogLines" "liveItem" ",C1,C2" \
  && ok "catalogLines[].liveItem = [,C1,C2] (read-time LinkInChild, per element; null-FK null)" \
  || { bad "liveItem enrichment wrong"; tail -n 20 "$SERVER_LOG"; }

##############################################################################
sec "3. Segment filter into liveItem — shapes the segment, never the rows"
##############################################################################
title "3.1 ?catalogLines.liveItem.label=C1 attaches liveItem only on matching lines"
lget "$BASE/qa/catalogs-full" "catalogLines.liveItem.label=C1"
LV=$(jchild_file "$GET_TMP" catalogLines liveItem)
# LEFT/per-element: C1 attaches, C2 & null-FK line → empty → sorted ",,C1"
[ "$LV" = ",,C1" ] && ok "liveItem filtered per element to [,,C1]" || bad "segment filter wrong: $LV"

title "3.2 A segment filter NEVER drops primary rows or child lines"
{ [ "$(lcount)" = "1" ] && [ "$(nlines "$GET_TMP" catalogLines)" = "3" ]; } \
  && ok "still 1 catalog / 3 lines (filter shapes the segment, not row/line selection)" \
  || bad "segment filter dropped rows/lines: rows=$(lcount) lines=$(nlines "$GET_TMP" catalogLines)"

title "3.3 A match-nothing filter → every liveItem null, rows/lines intact"
lget "$BASE/qa/catalogs-full" "catalogLines.liveItem.label=does-not-exist"
LV=$(jchild_file "$GET_TMP" catalogLines liveItem)
{ [ "$LV" = ",," ] && [ "$(lcount)" = "1" ] && [ "$(nlines "$GET_TMP" catalogLines)" = "3" ]; } \
  && ok "no match → all liveItem null; still 1 catalog / 3 lines (no false positives)" \
  || bad "match-nothing filter wrong: liveItem='$LV' rows=$(lcount) lines=$(nlines "$GET_TMP" catalogLines)"

title "3.4 Segment filter AND-ed with a root filter still selects the row"
lget "$BASE/qa/catalogs-full" "name=LIC Collection" "catalogLines.liveItem.label=C2"
{ [ "$(lcount)" = "1" ] && [ "$(jchild_file "$GET_TMP" catalogLines liveItem)" = ",,C2" ]; } \
  && ok "root filter selects the row; segment filter shapes liveItem to [,,C2]" \
  || bad "combined root+segment filter wrong"

##############################################################################
sec "4. ?fields= — the LinkInChild leg is fetched ONLY when its segment is asked"
##############################################################################
title "4.1 ?fields=catalogLines.liveItem.label prunes to the enrichment"
lget "$BASE/qa/catalogs-full" "fields=catalogLines.liveItem.label"
LV=$(jchild_file "$GET_TMP" catalogLines liveItem)
[ "$LV" = ",C1,C2" ] && ok "liveItem survives a sparse ?fields= projection ($LV)" || bad "fields projection wrong: $LV"

title "4.2 ?fields=name (no in-child segment) → the LinkInChild leg is NOT fetched"
lget "$BASE/qa/catalogs-full" "fields=name"
{ [ "$(haskey_count "$GET_TMP" catalogLines liveItem)" = "0" ]; } \
  && ok "liveItem absent when unrequested (leg fetched only on demand)" \
  || bad "liveItem present despite not being projected"

title "4.3 ?fields=catalogLines.note (a child's OWN field) → liveItem NOT fetched"
lget "$BASE/qa/catalogs-full" "fields=catalogLines.note"
{ [ "$(haskey_count "$GET_TMP" catalogLines note)" = "3" ] && [ "$(haskey_count "$GET_TMP" catalogLines liveItem)" = "0" ]; } \
  && ok "a child own-field projection keeps the line but never fetches the LinkInChild leg" \
  || bad "child-field projection leaked the LinkInChild leg (note=$(haskey_count "$GET_TMP" catalogLines note) live=$(haskey_count "$GET_TMP" catalogLines liveItem))"

##############################################################################
sec "5. Sort into a segment is rejected (order is the primary's)"
##############################################################################
title "5.1 ?orderBy=catalogLines.liveItem.label → 400"
CODE=$(http_code "$BASE/qa/catalogs-full" "orderBy=catalogLines.liveItem.label")
[ "$CODE" = "400" ] && ok "sort into the liveItem segment rejected with 400" || bad "expected 400, got $CODE"

##############################################################################
sec "6. Read-time ripple: rename the item; liveItem updates on next read"
##############################################################################
title "6.1 PATCH item C1 → C1-live; upstream ripples; liveItem reflects it"
curl -sS -o /dev/null -X PATCH "$BASE/qa/items/$L1_ID" -H "Content-Type: application/json" --data '{"label":"C1-live"}'
wait_child "$CAT_FULL_URL" "catalogLines" "liveItem" ",C1-live,C2" \
  && ok "liveItem = [,C1-live,C2] after the item rename (composed doc never materialized)" \
  || bad "read-time ripple into liveItem failed"

##############################################################################
sec "7. CSV export walks the liveItem branch"
##############################################################################
title "7.1 /qa/catalogs-full.csv carries a liveItem label"
curl -sS -o "$GET_TMP" "$BASE/qa/catalogs-full.csv"
grep -q "C1-live" "$GET_TMP" && ok "catalogs-full.csv carries the read-time liveItem label" || bad "CSV missing liveItem data"

##############################################################################
hr; printf '\033[1;37mLinkInChild: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
