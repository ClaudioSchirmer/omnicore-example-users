#!/usr/bin/env bash
# RelationalSource view suite — the read-side twins served straight from the
# relational SoR instead of the Mongo projection. It mirrors the GETs that go to
# the Mongo views over to the RelationalSource views and asserts:
#
#   1. PARITY on root-servable reads — the relational twin returns the SAME result
#      as the Mongo view (and the same hard-coded expected counts) for every root
#      filter operator, sort, ?fields=, pagination, ?onlyTotal, ?includeArchived
#      and by-id. Proven on the flat gadgets + lens-brands twins.
#   2. READ-YOUR-WRITES — the relational twin reads the SoR directly, so a
#      just-written row is visible with NO CDC wait (contrast: the Mongo view needs
#      the outbox→CDC→SyncEngine hop). Asserted before the connector even warms.
#   3. 1:1 SATELLITE PARITY vs 1:N 400 — a root-level 1:1 sibling field (material,
#      on the Widget twin) and a shared-base field (displayName, on the AccountHolder
#      twin) filter/sort identically to the Mongo view: the loader LEFT JOINs the
#      satellite in. But a 1:N child field (widgetParts.label) or a child-level
#      sibling (widgetParts.tag) is a pushdown a single root SELECT cannot express,
#      so it stays 400 RelationalCapabilityNotification — the SAME query row-selects
#      on the Mongo view, the contrast the suite asserts side by side. ?search= is
#      likewise 400.
#   4. CEILINGS — the relational reader honors MaxLimit (?first over the cap → 400
#      LimitExceededNotification) and MaxExportRows (CSV/XLSX truncates at the cap),
#      exactly like the Mongo reader, plus CSV/XLSX content parity.
#
# Self-managed; qa binary (-tags '<engine> qa') + microservice.qa.yaml.
# Dialect-driven via qa/_backend.sh.  Run from anywhere:  bash qa/relational_view.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-relational-view-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-relational-view-${BACKEND:-postgres}.log"

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
  qa_view_drop gadgets gadgets_hot gadgets_capped gadget_notes qa_lens_brands_view qa_widgets_view qa_accounts_view upstream_gadgets
}
trap cleanup EXIT INT TERM

# ── helpers ─────────────────────────────────────────────────────────────────
# data length of a JSON body file (-1 on any error).
len_of() { python3 -c 'import sys,json
try:
  d=json.load(open(sys.argv[1])); data=d.get("data",[])
  print(len(data) if isinstance(data,list) else -1)
except Exception: print(-1)' "$1"; }

# ids_of — the sorted list of aggregate ids in a listing body ("ERR" on parse
# failure, "" for an empty/objectless list). Every view doc carries the SAME
# aggregate id whether served from Mongo or the SoR, so comparing the id sets of
# the two backings proves they returned the SAME ROWS — not merely the same
# COUNT (a reader returning the wrong rows with the right count is caught here).
ids_of() { python3 -c 'import sys,json
try:
  data=json.load(open(sys.argv[1])).get("data",[])
  print("\n".join(sorted(str(x.get("id") or x.get("_id") or "") for x in data)) if isinstance(data,list) else "ERR")
except Exception: print("ERR")' "$1"; }

# total_of <curl-args…> — the pagination.totalCount of a listing. Prints "<absent>"
# when the key is missing, so an OMITTED total is never mistaken for a real 0 —
# the distinction the relational listing bug turned on (it emitted a literal 0).
total_of() { curl -sS "$@" | python3 -c 'import sys,json
try:
  print(json.load(sys.stdin).get("pagination",{}).get("totalCount","<absent>"))
except Exception: print("<err>")'; }

# first notificationKey found anywhere in a JSON body file ("" if none).
notif_key() { python3 -c 'import sys,json
def walk(o,acc):
  if isinstance(o,dict):
    if "notificationKey" in o: acc.append(o["notificationKey"])
    for v in o.values(): walk(v,acc)
  elif isinstance(o,list):
    for v in o: walk(v,acc)
try:
  acc=[]; walk(json.load(open(sys.argv[1])),acc); print(acc[0] if acc else "")
except Exception: print("")' "$1"; }

# qargs <qs> — populate the global CURL_ARGS array with one --data-urlencode per
# &-separated key=value pair, so a multi-parameter query string (and values with
# spaces) survive intact (a single --data-urlencode would encode the & itself).
qargs() {
  CURL_ARGS=(-G)
  local qs="$1"
  if [ -n "$qs" ]; then
    local IFS='&' kv
    for kv in $qs; do [ -n "$kv" ] && CURL_ARGS+=(--data-urlencode "$kv"); done
  fi
}

# rel <name> <path> <qs> <expected> — GET a relational twin, assert 200 + count.
rel() {
  local name="$1" path="$2" qs="$3" want="$4"
  title "$name"
  local tmp; tmp=$(mktemp)
  qargs "$qs"
  local st; st=$(curl -sS -o "$tmp" -w "%{http_code}" "${CURL_ARGS[@]}" "$BASE$path")
  local n; n=$(len_of "$tmp")
  echo "GET $path?$qs → status=$st items=$n"
  if [ "$st" = "200" ] && [ "$n" = "$want" ]; then ok "$name (items=$n)"; else bad "$name (want 200/$want, got $st/$n)"; head -c 300 "$tmp"; echo; fi
  rm -f "$tmp"
}

# parity <name> <mongo-path> <rel-path> <qs> <expected> — assert BOTH the Mongo
# view and its relational twin return 200 with EXACTLY <expected> items.
parity() {
  local name="$1" mpath="$2" rpath="$3" qs="$4" want="$5"
  title "$name"
  local mt rt ms rs mn rn
  mt=$(mktemp); rt=$(mktemp)
  qargs "$qs"
  ms=$(curl -sS -o "$mt" -w "%{http_code}" "${CURL_ARGS[@]}" "$BASE$mpath")
  rs=$(curl -sS -o "$rt" -w "%{http_code}" "${CURL_ARGS[@]}" "$BASE$rpath")
  mn=$(len_of "$mt"); rn=$(len_of "$rt")
  local mids rids same=no
  mids=$(ids_of "$mt"); rids=$(ids_of "$rt")
  [ "$mids" = "$rids" ] && same=yes
  echo "mongo $mpath?$qs → $ms/$mn   rel $rpath?$qs → $rs/$rn   (want $want, same-rows=$same)"
  if [ "$ms" = "200" ] && [ "$rs" = "200" ] && [ "$mn" = "$want" ] && [ "$rn" = "$want" ] && [ "$same" = "yes" ]; then
    ok "$name (mongo=$mn rel=$rn, same rows)"
  else
    bad "$name (want 200/$want both + identical rows, got mongo $ms/$mn rel $rs/$rn same-rows=$same)"
  fi
  rm -f "$mt" "$rt"
}

# reject4xx <name> <path> <qs> — assert the relational twin rejects with 400 AND
# the RelationalCapabilityNotification key.
reject4xx() {
  local name="$1" path="$2" qs="$3"
  title "$name"
  local tmp; tmp=$(mktemp)
  qargs "$qs"
  local st; st=$(curl -sS -o "$tmp" -w "%{http_code}" "${CURL_ARGS[@]}" "$BASE$path")
  local k; k=$(notif_key "$tmp")
  echo "GET $path?$qs → status=$st notif=$k"
  if [ "$st" = "400" ] && [ "$k" = "RelationalCapabilityNotification" ]; then ok "$name (400 $k)"; else bad "$name (want 400/RelationalCapabilityNotification, got $st/$k)"; fi
  rm -f "$tmp"
}

# status_is <name> <url> <expected-code> [expected-notif]
status_is() {
  local name="$1" url="$2" code="$3" key="${4:-}"
  title "$name"
  local tmp; tmp=$(mktemp)
  local st; st=$(curl -sS -o "$tmp" -w "%{http_code}" "$url")
  local k; k=$(notif_key "$tmp")
  if [ "$st" = "$code" ] && { [ -z "$key" ] || [ "$k" = "$key" ]; }; then ok "$name ($st${key:+ $k})"; else bad "$name (want $code${key:+/$key}, got $st${key:+/$k})"; fi
  rm -f "$tmp"
}

##############################################################################
sec "0. Build + connector + boot"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"

title "0.2 Ensure the outbox Debezium connector is registered ($QA_CONNECTOR_DIALECT)"
"$REPO_ROOT/devops/debezium/register-connector.sh" "$QA_CONNECTOR_DIALECT" >/dev/null 2>&1 \
  && ok "outbox connector registered" || bad "outbox connector registration failed"

title "0.3 Start server (APP_PROFILE=dev, config=microservice.qa.yaml)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$REPO_ROOT/microservice.qa.yaml" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready (PID=$SERVER_PID)" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }

title "0.4 Reset the source tables"
qa_db_exec "DELETE FROM gadgets;"
qa_db_exec "DELETE FROM qa_lens_brands;"
qa_db_exec "DELETE FROM qa_widget_part_tags;" 2>/dev/null || true
qa_db_exec "DELETE FROM qa_widget_parts;" 2>/dev/null || true
qa_db_exec "DELETE FROM qa_widget_specs;" 2>/dev/null || true
qa_db_exec "DELETE FROM qa_widgets;"
qa_view_clear gadgets
qa_view_clear qa_lens_brands_view
qa_view_clear qa_widgets_view
sleep 1

##############################################################################
sec "1. Seed the fixtures + read-your-writes (the SoR twin sees writes, NO CDC)"
##############################################################################
qa_cdc_warmup_gadget
seed_g() { curl -sS -o /dev/null -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" \
  --data "{\"code\":\"$1\",\"name\":\"$2\",\"category\":\"$3\",\"status\":\"$4\"}"; }
seed_g "GADGET-01" "Alpha One"     "cat-a" "active"
seed_g "GADGET-02" "Bravo Two"     "cat-a" "inactive"
seed_g "GADGET-03" "Charlie Three" "cat-b" "active"
seed_g "GADGET-04" "Delta Four"    "cat-c" "retired"
for name in "Zeiss" "Leica" "Nikon"; do
  curl -sS -o /dev/null -X POST "$BASE/qa/lens-brands" -H "Content-Type: application/json" --data "{\"name\":\"$name\"}"
done
curl -sS -o /dev/null -X POST "$BASE/qa/widgets" -H "Content-Type: application/json" \
  --data '{"name":"Widget A","material":"aluminium","parts":[{"label":"lens","slot":0,"tag":"optical"},{"label":"grip","slot":1,"tag":"rubber"}]}'
curl -sS -o /dev/null -X POST "$BASE/qa/widgets" -H "Content-Type: application/json" \
  --data '{"name":"Widget B","material":"steel","parts":[{"label":"bolt","slot":0,"tag":"metal"}]}'

# Read-your-writes: the relational twins hit the SoR directly, so every row just
# POSTed is already visible with NO CDC wait — the Mongo views (section 2) still
# lag behind the outbox→CDC→SyncEngine hop at this point.
rel "1.1 gadgets twin sees all 4 writes immediately"  "/qa/rel/gadgets"     "code.startswith=GADGET" 4
rel "1.2 brands twin sees all 3 writes immediately"   "/qa/rel/lens-brands" ""                       3
rel "1.3 widgets twin sees both writes immediately"   "/qa/rel/widgets"     "name.icontains=widget"  2

##############################################################################
sec "2. Wait for the Mongo views to materialize (CDC)"
##############################################################################
title "2.1 Poll the three Mongo views"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); seeded=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  g=$(curl -sS "$BASE/qa/gadgets?code.startswith=GADGET" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("data",[])))' 2>/dev/null)
  b=$(curl -sS "$BASE/qa/lens-brands" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("data",[])))' 2>/dev/null)
  w=$(curl -sS "$BASE/qa/widgets?name.icontains=widget" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("data",[])))' 2>/dev/null)
  [ "${g:-0}" = "4" ] && [ "${b:-0}" = "3" ] && [ "${w:-0}" = "2" ] && { seeded=ok; break; }
  sleep 1
done
[ "$seeded" = ok ] && ok "gadgets=4 brands=3 widgets=2 materialized" || bad "views did not materialize (g=${g:-0} b=${b:-0} w=${w:-0})"

##############################################################################
sec "3. Gadgets parity — relational twin == Mongo view == expected (root filters)"
##############################################################################
parity "3.1  code.eq"          "/qa/gadgets" "/qa/rel/gadgets" "code.eq=GADGET-02"            1
parity "3.2  code.in"          "/qa/gadgets" "/qa/rel/gadgets" "code.in=GADGET-01,GADGET-03" 2
parity "3.3  code.nin"         "/qa/gadgets" "/qa/rel/gadgets" "code.nin=GADGET-01,GADGET-02" 2
parity "3.4  code.gte"         "/qa/gadgets" "/qa/rel/gadgets" "code.gte=GADGET-03"          2
parity "3.5  code.lt"          "/qa/gadgets" "/qa/rel/gadgets" "code.lt=GADGET-02"           1
parity "3.6  code.startswith"  "/qa/gadgets" "/qa/rel/gadgets" "code.startswith=GADGET"      4
parity "3.7  name.eq"          "/qa/gadgets" "/qa/rel/gadgets" "name.eq=Alpha One"           1
parity "3.8  name.ne"          "/qa/gadgets" "/qa/rel/gadgets" "name.ne=Alpha One"           3
parity "3.9  name.contains"    "/qa/gadgets" "/qa/rel/gadgets" "name.contains=Three"         1
parity "3.10 name.icontains"   "/qa/gadgets" "/qa/rel/gadgets" "name.icontains=three"        1
parity "3.11 name.istartswith" "/qa/gadgets" "/qa/rel/gadgets" "name.istartswith=alpha"      1
parity "3.12 category.eq"      "/qa/gadgets" "/qa/rel/gadgets" "category.eq=cat-a"           2
parity "3.13 category.in"      "/qa/gadgets" "/qa/rel/gadgets" "category.in=cat-b,cat-c"     2
parity "3.14 category.iin"     "/qa/gadgets" "/qa/rel/gadgets" "category.iin=CAT-A"          2
parity "3.15 status.ne"        "/qa/gadgets" "/qa/rel/gadgets" "status.ne=active"            2
parity "3.16 no filter (all)"    "/qa/gadgets" "/qa/rel/gadgets" ""                          4

##############################################################################
sec "4. Gadgets parity — sort, fields, pagination, onlyTotal, includeArchived, by-id"
##############################################################################
title "4.1 sort asc/desc — same first code on both backings"
for dir in "code" "-code"; do
  mf=$(curl -sS "$BASE/qa/gadgets?orderBy=$dir&first=1" | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(d[0]["code"] if d else "")')
  rf=$(curl -sS "$BASE/qa/rel/gadgets?orderBy=$dir&first=1" | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(d[0]["code"] if d else "")')
  [ -n "$mf" ] && [ "$mf" = "$rf" ] && ok "orderBy=$dir first code parity ($mf)" || bad "orderBy=$dir first code mongo=$mf rel=$rf"
done

title "4.2 ?fields= projection parity — relational twin prunes to the SAME keys as Mongo"
keys_of() { curl -sS "$1" | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data",[])
print(",".join(sorted(d[0].keys())) if d else "<empty>")'; }
mfields=$(keys_of "$BASE/qa/gadgets?code.eq=GADGET-01&fields=code")
rfields=$(keys_of "$BASE/qa/rel/gadgets?code.eq=GADGET-01&fields=code")
echo "fields=code → mongo=[$mfields] rel=[$rfields]"
[ -n "$mfields" ] && [ "$mfields" = "$rfields" ] && ok "?fields=code parity ($rfields)" || bad "?fields=code mongo=[$mfields] rel=[$rfields]"
mfields2=$(keys_of "$BASE/qa/gadgets?code.eq=GADGET-01&fields=code,status")
rfields2=$(keys_of "$BASE/qa/rel/gadgets?code.eq=GADGET-01&fields=code,status")
echo "fields=code,status → mongo=[$mfields2] rel=[$rfields2]"
[ -n "$mfields2" ] && [ "$mfields2" = "$rfields2" ] && ok "?fields=code,status parity ($rfields2)" || bad "?fields=code,status mongo=[$mfields2] rel=[$rfields2]"

title "4.3 ?onlyTotal — count parity, no items"
mt=$(curl -sS "$BASE/qa/gadgets?onlyTotal=true" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("totalCount"))')
rt=$(curl -sS "$BASE/qa/rel/gadgets?onlyTotal=true" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("totalCount"))')
[ "$mt" = "4" ] && [ "$rt" = "4" ] && ok "onlyTotal parity (mongo=$mt rel=$rt)" || bad "onlyTotal mongo=$mt rel=$rt"

title "4.3b total on a NORMAL listing — the count must NOT depend on ?onlyTotal"
# 4.3 above compares the two backings in COUNT-ONLY mode — the one mode that
# always worked. The relational reader used to assign Total only in that
# short-circuit, so an ordinary listing served its items beside a literal
# "totalCount": 0, and a consumer paging a 47-row result read 0 on every page while
# ?onlyTotal=true answered 47. These three assertions pin the listing path: the
# count is the FULL match set (not the page size, not 0), it matches the Mongo
# twin, and it matches what the same backing reports in only-total mode.
mlt=$(total_of "$BASE/qa/gadgets?orderBy=code&first=2")
rlt=$(total_of "$BASE/qa/rel/gadgets?orderBy=code&first=2")
rln=$(curl -sS "$BASE/qa/rel/gadgets?orderBy=code&first=2" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]))')
echo "first=2 → mongo total=$mlt  rel total=$rlt  rel items=$rln"
[ "$rln" = "2" ] && [ "$rlt" = "4" ] && ok "relational listing reports the FULL count (total=$rlt over a 2-row page)" || bad "relational listing total=$rlt items=$rln (want total 4 over 2 items)"
[ "$mlt" = "$rlt" ] && ok "listing total parity (mongo=$mlt rel=$rlt)" || bad "listing total mongo=$mlt rel=$rlt"
[ "$rlt" = "$rt" ] && ok "relational listing total == its own onlyTotal ($rlt)" || bad "relational listing total=$rlt but its onlyTotal=$rt"

title "4.3c total under a ROOT filter, on an EMPTY set, and with ?fields="
# The count runs the request's own criteria, so a filter shapes it; a set that
# matches nothing reports an HONEST 0 (the value the bug produced everywhere, so
# it must still be reachable for the right reason); and a projection prunes the
# DOCUMENT, never the count — ?fields= must leave total untouched.
fmt=$(total_of "$BASE/qa/gadgets?category.eq=cat-a")
frt=$(total_of "$BASE/qa/rel/gadgets?category.eq=cat-a")
[ "$frt" = "2" ] && [ "$fmt" = "$frt" ] && ok "root filter shapes total (cat-a → $frt, mongo=$fmt)" || bad "root-filtered total mongo=$fmt rel=$frt (want 2 both)"
emt=$(total_of "$BASE/qa/gadgets?code.eq=NOPE-99")
ert=$(total_of "$BASE/qa/rel/gadgets?code.eq=NOPE-99")
[ "$ert" = "0" ] && [ "$emt" = "$ert" ] && ok "empty result set → an honest total 0 (mongo=$emt rel=$ert)" || bad "empty-set total mongo=$emt rel=$ert (want 0 both)"
pmt=$(total_of "$BASE/qa/gadgets?fields=code&first=1")
prt=$(total_of "$BASE/qa/rel/gadgets?fields=code&first=1")
[ "$prt" = "4" ] && [ "$pmt" = "$prt" ] && ok "?fields= prunes the doc, not the count (total=$prt)" || bad "?fields= total mongo=$pmt rel=$prt (want 4 both)"

title "4.4 pagination — limit + after walks the full set once, no dups"
cur=$(curl -sS "$BASE/qa/rel/gadgets?orderBy=code&first=2" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("endCursor",""))')
echo "page1 endCursor: ${cur:0:16}…"
# The cursor is base64 (may carry +/=), so pass it through --data-urlencode.
p2=$(curl -sS -G "$BASE/qa/rel/gadgets" --data-urlencode "orderBy=code" --data-urlencode "first=2" --data-urlencode "after=$cur" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]))')
[ -n "$cur" ] && [ "$p2" = "2" ] && ok "relational after-cursor returns the second page (2)" || bad "after-cursor page2 got $p2 (cursor=${cur:0:12})"
# total is a property of the MATCH SET, not of the window — it must not drift as
# the cursor walks. (The `after` branch takes a different path through the window
# resolver than the default first page.)
p2t=$(total_of -G "$BASE/qa/rel/gadgets" --data-urlencode "orderBy=code" --data-urlencode "first=2" --data-urlencode "after=$cur")
[ "$p2t" = "4" ] && ok "the after-cursor page still reports the full total (4)" || bad "after-cursor page total=$p2t (want 4)"

title "4.4b before the FIRST row (offset-0 cursor) → EMPTY page, never a full-table dump"
# Paging `before` a cursor that points at offset 0 must return an EMPTY page — a
# regression guard for the zero-fetch window that would otherwise emit no LIMIT
# clause and stream the whole table (bypassing MaxLimit).
#
# The offset-0 cursor is sourced from the GraphQL connection's edges[].cursor,
# NOT from a page-level startCursor. Page 1 no longer carries one: an edge cursor
# is emitted only where its neighbouring page exists, and nothing sits before the
# head. Per-ROW cursors are not gated by that rule — that is exactly the split
# between ItemCursors (addresses a row) and the page edges (address boundaries) —
# so edges[0].cursor still addresses the first row and remains the honest way to
# ask for "the page before this row". It round-trips into ?before= because both
# requests carry the same listing context (no filter, orderBy=code), which is
# what the cursor's context hash binds.
prev=$(curl -sS -X POST "$BASE/graphql" -H "Content-Type: application/json" \
  --data '{"query":"query { gadgetsRel(orderBy: [{field: CODE}], first: 1) { edges { cursor } } }"}' \
  | python3 -c 'import sys,json
try:
  c=(json.load(sys.stdin).get("data") or {}).get("gadgetsRel") or {}
  e=c.get("edges") or []
  print(e[0].get("cursor","") if e else "")
except Exception: print("")')
bcount=$(curl -sS -G "$BASE/qa/rel/gadgets" --data-urlencode "orderBy=code" --data-urlencode "last=2" --data-urlencode "before=$prev" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]))')
[ -n "$prev" ] && [ "$bcount" = "0" ] && ok "before-first-row returns an empty page (0)" || bad "before-first-row expected 0 items, got ${bcount:-?} (prev=${prev:0:12})"
# That zero-width window returns WITHOUT issuing the row query — its own early
# return. An empty PAGE is not an empty RESULT SET, so it must still carry the
# count: 4, not 0.
bt=$(total_of -G "$BASE/qa/rel/gadgets" --data-urlencode "orderBy=code" --data-urlencode "last=2" --data-urlencode "before=$prev")
[ "$bt" = "4" ] && ok "the zero-width window still reports the full total (4)" || bad "zero-width window total=$bt (want 4 — an empty page is not an empty set)"

title "4.5 by-id parity — same document from both backings"
GID=$(curl -sS "$BASE/qa/rel/gadgets?code.eq=GADGET-03" | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(d[0]["id"] if d else "")')
mdoc=$(curl -sS "$BASE/qa/gadgets/$GID" | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data",{});print(d.get("code"),d.get("name"),d.get("category"),d.get("status"))')
rdoc=$(curl -sS "$BASE/qa/rel/gadgets/$GID" | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data",{});print(d.get("code"),d.get("name"),d.get("category"),d.get("status"))')
[ -n "$GID" ] && [ "$mdoc" = "$rdoc" ] && ok "by-id doc parity ($rdoc)" || bad "by-id mongo=[$mdoc] rel=[$rdoc]"

title "4.6 includeArchived parity — archive GADGET-04, both hide it, both show with the flag"
G4=$(curl -sS "$BASE/qa/rel/gadgets?code.eq=GADGET-04" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][0]["id"])')
curl -sS -o /dev/null -X PATCH "$BASE/qa/gadgets/$G4/archive"
# The relational twin hides it instantly (deleted_at gate); the Mongo view needs
# the archive to propagate via CDC — wait for the default view to drop to 3.
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); arch=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  mg=$(curl -sS "$BASE/qa/gadgets?code.startswith=GADGET" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("data",[])))' 2>/dev/null)
  [ "${mg:-0}" = "3" ] && { arch=ok; break; }
  sleep 1
done
[ "$arch" = ok ] && ok "4.6 archive propagated to the Mongo view" || bad "4.6 archive did not propagate (mongo=${mg:-0})"
parity "4.6a default hides the archived gadget" "/qa/gadgets" "/qa/rel/gadgets" "code.startswith=GADGET" 3
parity "4.6b includeArchived surfaces it"        "/qa/gadgets" "/qa/rel/gadgets" "code.startswith=GADGET&includeArchived=true" 4

title "4.6c total follows the ARCHIVED gate — the count is scoped like the rows"
# The count is taken under the same archived scope as the row query, so archiving
# one gadget must move total from 4 to 3, and ?includeArchived must bring it back.
amt=$(total_of "$BASE/qa/gadgets?code.startswith=GADGET")
art=$(total_of "$BASE/qa/rel/gadgets?code.startswith=GADGET")
[ "$art" = "3" ] && [ "$amt" = "$art" ] && ok "default read counts the 3 ACTIVE gadgets (mongo=$amt rel=$art)" || bad "default-read total mongo=$amt rel=$art (want 3 both)"
imt=$(total_of "$BASE/qa/gadgets?code.startswith=GADGET&includeArchived=true")
irt=$(total_of "$BASE/qa/rel/gadgets?code.startswith=GADGET&includeArchived=true")
[ "$irt" = "4" ] && [ "$imt" = "$irt" ] && ok "?includeArchived counts all 4 again (mongo=$imt rel=$irt)" || bad "includeArchived total mongo=$imt rel=$irt (want 4 both)"

##############################################################################
sec "5. Gadgets unsupported — ?search= → 400 (rel) vs 200 (mongo text search)"
##############################################################################
reject4xx "5.1 relational ?search= is rejected" "/qa/rel/gadgets" "search=Alpha"
status_is "5.2 mongo ?search= runs the text search (200)" "$BASE/qa/gadgets?search=Alpha" 200

##############################################################################
sec "6. Ceilings — MaxLimit + MaxExportRows on the capped twin, CSV parity"
##############################################################################
status_is "6.1 capped ?first=100 → 400 LimitExceeded"    "$BASE/qa/rel/gadgets-capped?first=100" 400 "LimitExceededNotification"
status_is "6.2 capped ?first=5 (at the cap) → 200"        "$BASE/qa/rel/gadgets-capped?first=5"   200
title "6.3 CSV export content parity (data rows) + MaxExportRows truncation"
full=$(curl -sS "$BASE/qa/rel/gadgets.csv?code.startswith=GADGET&includeArchived=true" | tail -n +2 | grep -c GADGET)
cap=$(curl -sS "$BASE/qa/rel/gadgets-capped.csv?code.startswith=GADGET&includeArchived=true" | tail -n +2 | grep -c GADGET)
[ "$full" = "4" ] && ok "full CSV carries all 4 rows" || bad "full CSV rows=$full (want 4)"
[ "$cap" = "3" ]  && ok "capped CSV truncates at MaxExportRows=3" || bad "capped CSV rows=$cap (want 3)"
title "6.4 XLSX export is a valid workbook (PK zip magic)"
magic=$(curl -sS "$BASE/qa/rel/gadgets.xlsx?code.startswith=GADGET" | head -c 2)
[ "$magic" = "PK" ] && ok "XLSX magic OK" || bad "XLSX not a zip (magic=$magic)"

##############################################################################
sec "7. Lens-brands twin — a second flat view family, parity"
##############################################################################
parity "7.1 brand name.eq"       "/qa/lens-brands" "/qa/rel/lens-brands" "name.eq=Leica"     1
parity "7.2 brand name.contains" "/qa/lens-brands" "/qa/rel/lens-brands" "name.contains=e"   2
parity "7.3 all brands"          "/qa/lens-brands" "/qa/rel/lens-brands" ""                  3

##############################################################################
sec "8. Widgets twin — 1:1 sibling fields reach parity; 1:N child fields → 400"
##############################################################################
title "8.1 root name is served identically (parity)"
parity "8.1 name parity" "/qa/widgets" "/qa/rel/widgets" "name.eq=Widget A" 1

title "8.2 a root-level 1:1 sibling filter/sort now reaches parity (LEFT JOIN)"
# material lives in the qa_widget_specs 1:1 sibling — the loader LEFT JOINs it, so
# the relational twin filters AND sorts by it identically to the Mongo view (the
# id tiebreak is qualified to qa_widgets under the join, no ambiguity).
parity "8.2a material.eq (root sibling → 1:1 JOIN)" "/qa/widgets" "/qa/rel/widgets" "material.eq=steel" 1
parity "8.2b orderBy=material (root sibling)"       "/qa/widgets" "/qa/rel/widgets" "orderBy=material"     2

title "8.2c total under a SIBLING filter/sort — the COUNT joins the satellite too"
# The count runs the same scoped criteria as the row query, so it crosses the same
# LEFT JOIN. Two distinct failure modes are pinned here: a count that skipped the
# join would report both widgets under a sibling filter (2, not 1), and a count
# that merely echoed the window would report the page size (1, not 2) under a
# sibling sort. Both are checked against the Mongo twin.
smt=$(total_of "$BASE/qa/widgets?material.eq=steel&first=1")
srt=$(total_of "$BASE/qa/rel/widgets?material.eq=steel&first=1")
echo "material.eq=steel&first=1 → mongo total=$smt  rel total=$srt"
[ "$srt" = "1" ] && ok "sibling FILTER shapes total (1, not the unfiltered 2)" || bad "sibling-filtered total=$srt (want 1)"
[ "$smt" = "$srt" ] && ok "sibling-filtered total parity (mongo=$smt rel=$srt)" || bad "sibling-filtered total mongo=$smt rel=$srt"
omt=$(total_of "$BASE/qa/widgets?orderBy=material&first=1")
ort=$(total_of "$BASE/qa/rel/widgets?orderBy=material&first=1")
echo "orderBy=material&first=1 → mongo total=$omt  rel total=$ort"
[ "$ort" = "2" ] && ok "sibling SORT keeps total at the full set (2, not the 1-row page)" || bad "sibling-sorted total=$ort (want 2)"
[ "$omt" = "$ort" ] && ok "sibling-sorted total parity (mongo=$omt rel=$ort)" || bad "sibling-sorted total mongo=$omt rel=$ort"

title "8.3 a 1:N child field (or a child-level sibling) is still 400 on the twin"
# widgetParts is a 1:N child array, and its tag a child-level sibling — a single
# root SELECT cannot push those down, so the relational twin rejects them 400 …
reject4xx "8.3a widgetParts.label (1:N child field)"     "/qa/rel/widgets" "widgetParts.label.eq=lens"
reject4xx "8.3b widgetParts.tag (child-level sibling)"   "/qa/rel/widgets" "widgetParts.tag.eq=optical"
reject4xx "8.3c orderBy=widgetParts.label (1:N child)"   "/qa/rel/widgets" "orderBy=widgetParts.label"
# … while the SAME queries row-select on the Mongo view (the contrast).
status_is "8.3d mongo widgetParts.label.eq → 200"  "$BASE/qa/widgets?widgetParts.label.eq=lens" 200
mn=$(curl -sS "$BASE/qa/widgets?widgetParts.tag.eq=optical" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("data",[])))')
[ "$mn" = "1" ] && ok "8.3e mongo widgetParts.tag.eq=optical selects the 1 matching widget" || bad "8.3e mongo child row-select got $mn (want 1)"

title "8.4 by-id parity — the relational twin surfaces the SAME nested doc (material + parts + tag)"
WID=$(curl -sS "$BASE/qa/rel/widgets?name.eq=Widget%20A" | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(d[0]["id"] if d else "")')
mdoc=$(curl -sS "$BASE/qa/widgets/$WID" | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data",{})
parts=sorted((p.get("label"),p.get("tag")) for p in d.get("widgetParts",[]))
print(d.get("name"),d.get("material"),parts)')
rdoc=$(curl -sS "$BASE/qa/rel/widgets/$WID" | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data",{})
parts=sorted((p.get("label"),p.get("tag")) for p in d.get("widgetParts",[]))
print(d.get("name"),d.get("material"),parts)')
[ -n "$WID" ] && [ "$mdoc" = "$rdoc" ] && ok "widget by-id nested doc parity ($rdoc)" || bad "widget by-id mongo=[$mdoc] rel=[$rdoc]"

# The ?fields= projection is a LIST-endpoint control (the by-id request DTO does
# not opt into it), so these read the list filtered to Widget A. Helpers take the
# first widget doc of the "data" array.
wid_first_doc='import sys,json
d=json.load(sys.stdin).get("data",[])
d = d[0] if isinstance(d,list) and d else (d if isinstance(d,dict) else {})'
part_keys_of() { curl -sS -G "$1" "${@:2}" | python3 -c "$wid_first_doc"'
wp=d.get("widgetParts",[])
print(",".join(sorted(wp[0].keys())) if wp else "<none>")'; }
labels_of()   { curl -sS -G "$1" "${@:2}" | python3 -c "$wid_first_doc"'
print(",".join(sorted(p.get("label","") for p in d.get("widgetParts",[]))))'; }

title "8.5 ?fields=widgetParts.label prunes each part to the LEAF, SAME shape as Mongo (Fix #6)"
# Projection into a child array (a LIST control; child filter/sort are still 400).
# The relational reader composes the aggregate then applies Mongo's nested
# projection semantics — each part comes back with only 'label', not the whole
# element — so the shapes match the Mongo view.
mk=$(part_keys_of "$BASE/qa/widgets"     --data-urlencode "name.eq=Widget A" --data-urlencode "fields=widgetParts.label")
rk=$(part_keys_of "$BASE/qa/rel/widgets" --data-urlencode "name.eq=Widget A" --data-urlencode "fields=widgetParts.label")
echo "widgetParts[0] keys → mongo=[$mk] rel=[$rk]"
[ "$mk" = "label" ] && [ "$rk" = "label" ] && ok "nested ?fields= prunes each part to label on BOTH backings" || bad "nested fields mongo=[$mk] rel=[$rk]"

title "8.6 archive strip runs UNDER a nested ?fields= that never names deletedAt (Fix #6 + strip order)"
# Soft-delete Widget A's 'grip' part directly in the SoR (the qa widget has no
# archive endpoint). CURRENT_TIMESTAMP is portable across all four dialects. The
# relational reader must still HIDE it on a default read even though the
# projection asks only for widgetParts.label — the active scope + archived strip
# run BEFORE the ?fields= prune, so a projection omitting deletedAt cannot
# resurrect an archived child.
qa_db_exec "UPDATE qa_widget_parts SET deleted_at = CURRENT_TIMESTAMP WHERE label = 'grip';"
def_labels=$(labels_of "$BASE/qa/rel/widgets" --data-urlencode "name.eq=Widget A" --data-urlencode "fields=widgetParts.label")
arc_labels=$(labels_of "$BASE/qa/rel/widgets" --data-urlencode "name.eq=Widget A" --data-urlencode "fields=widgetParts.label" --data-urlencode "includeArchived=true")
echo "default=[$def_labels] includeArchived=[$arc_labels]"
[ "$def_labels" = "lens" ] && ok "8.6a default hides the archived 'grip' under ?fields=widgetParts.label" || bad "8.6a default labels=[$def_labels] (want lens)"
[ "$arc_labels" = "grip,lens" ] && ok "8.6b ?includeArchived surfaces both parts" || bad "8.6b includeArchived labels=[$arc_labels] (want grip,lens)"

##############################################################################
sec "9. Account holders twin — SHARED-BASE field parity (read-your-writes)"
##############################################################################
# The AccountHolder ROLE is served relationally over /qa/rel/account-holders. Its
# displayName + accountRef live in the qa_accounts BASE (1:1), so filtering and
# sorting by them exercises the loader's shared-base LEFT JOIN — the capability
# that used to return 400. No CDC: the SoR twin sees the writes immediately.
qa_db_exec "DELETE FROM qa_account_lines;"   2>/dev/null || true
qa_db_exec "DELETE FROM qa_account_holders;" 2>/dev/null || true
qa_db_exec "DELETE FROM qa_accounts;"
qa_view_clear qa_account_holders_rel 2>/dev/null || true

title "9.1 seed two account holders (distinct base displayName / accountRef)"
curl -sS -o /dev/null -X POST "$BASE/qa/accounts" -H "Content-Type: application/json" \
  --data '{"accountRef":"acct-acme","displayName":"ACME Corp","holderName":"Ada"}'
curl -sS -o /dev/null -X POST "$BASE/qa/accounts" -H "Content-Type: application/json" \
  --data '{"accountRef":"acct-globex","displayName":"Globex Inc","holderName":"Grace"}'
rel "9.1 twin sees both writes immediately (no CDC)" "/qa/rel/account-holders" "accountRef.startswith=acct-" 2

title "9.2 filter by a SHARED-BASE field — the loader LEFT JOINs qa_accounts in"
rel "9.2a displayName.eq (base field, exact)"        "/qa/rel/account-holders" "displayName.eq=ACME Corp"      1
rel "9.2b displayName.icontains (base field)"        "/qa/rel/account-holders" "displayName.icontains=globex" 1
rel "9.2c accountRef.eq (base natural key)"          "/qa/rel/account-holders" "accountRef.eq=acct-acme"      1
rel "9.2d no match on a base field → empty page"     "/qa/rel/account-holders" "displayName.eq=Nope"          0

title "9.3 sort by a SHARED-BASE field is accepted (ORDER BY the joined column + id tiebreak)"
rel "9.3a orderBy=displayName asc"  "/qa/rel/account-holders" "orderBy=displayName"  2
rel "9.3b orderBy=-displayName desc" "/qa/rel/account-holders" "orderBy=-displayName" 2

title "9.3c total under a SHARED-BASE filter — the count crosses the base JOIN too"
# 8.2c proved the count joins a 1:1 SIBLING; this proves the other satellite kind.
# displayName lives in the qa_accounts base, so a count that skipped the join
# would report both holders (2) instead of the one that matches.
bmt=$(total_of -G "$BASE/qa/rel/account-holders" --data-urlencode "displayName.eq=ACME Corp" --data-urlencode "first=1")
[ "$bmt" = "1" ] && ok "shared-base FILTER shapes total (1, not the unfiltered 2)" || bad "shared-base-filtered total=$bmt (want 1)"
bst=$(total_of "$BASE/qa/rel/account-holders?orderBy=displayName&first=1")
[ "$bst" = "2" ] && ok "shared-base SORT keeps total at the full set (2, not the 1-row page)" || bad "shared-base-sorted total=$bst (want 2)"

title "9.4 by-id surfaces the base fields flat on the role-rooted doc"
AID=$(curl -sS -G "$BASE/qa/rel/account-holders" --data-urlencode "accountRef.eq=acct-acme" | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data",[]);print(d[0]["id"] if d else "")')
disp=$(curl -sS "$BASE/qa/rel/account-holders/$AID" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("displayName",""))')
[ -n "$AID" ] && [ "$disp" = "ACME Corp" ] && ok "9.4 by-id displayName=ACME Corp (base field flat)" || bad "9.4 by-id base field, got id=[$AID] displayName=[$disp]"

##############################################################################
sec "10. GraphQL totalCount over a RELATIONAL view — the non-REST surface"
##############################################################################
# REST is not the only reader of queries.Page.Total: the GraphQL Relay connection
# fills totalCount from that SAME field (as gRPC's PaginationInfo.Total does). The
# `gadgetsRel` field resolves the RelationalSource view through the same handler
# the REST mirror uses, so this proves the count reaches a surface that never
# passes through handle_query.go's envelope. A totalCount-ONLY selection flips
# the reader into only-total mode, so both branches are asserted side by side.
# GADGET-04 was archived back in 4.6, so the active set here is 3.
gql() { curl -sS -X POST "$BASE/graphql" -H "Content-Type: application/json" \
  --data "{\"query\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")}"; }
gql_pick() { python3 -c 'import sys,json
try:
  c=json.load(sys.stdin).get("data",{}).get("gadgetsRel") or {}
  print(c.get("totalCount"), len(c.get("edges",[])))
except Exception: print("<err> <err>")'; }

title "10.1 a paged connection reports the FULL count, not the edge count"
read -r gtot gedges <<<"$(gql 'query { gadgetsRel(first: 2, orderBy: [{field: CODE}]) { totalCount edges { node { code } } } }' | gql_pick)"
echo "graphql gadgetsRel(first:2) → totalCount=$gtot edges=$gedges"
[ "$gedges" = "2" ] && [ "$gtot" = "3" ] && ok "GraphQL totalCount over a relational view = full count ($gtot over $gedges edges)" || bad "GraphQL relational totalCount=$gtot edges=$gedges (want 3 over 2)"

title "10.2 a totalCount-ONLY selection agrees with the paged one"
read -r gonly _ <<<"$(gql 'query { gadgetsRel { totalCount } }' | gql_pick)"
[ "$gonly" = "$gtot" ] && ok "GraphQL only-total selection agrees with the listing ($gonly)" || bad "GraphQL only-total totalCount=$gonly but the paged selection said $gtot"

title "10.3 the REST mirror of the same view agrees with the GraphQL connection"
# The Mongo gadgets view is not exposed on GraphQL (only `users` and these two
# qa fields are), so the cross-backing parity check stays on REST, where 4.3b
# already proves it. What is worth pinning here is cross-SURFACE agreement: the
# same relational view, read through two different envelopes, reports one number.
rest_tot=$(total_of "$BASE/qa/rel/gadgets?orderBy=code&first=2")
[ "$rest_tot" = "$gtot" ] && ok "same view, both surfaces agree (REST=$rest_tot GraphQL=$gtot)" || bad "surface disagreement: REST=$rest_tot GraphQL=$gtot"

##############################################################################
sec "11. gRPC PaginationInfo.total_count over a RELATIONAL view — the THIRD surface"
##############################################################################
# The last reader of queries.Page.Total. ListGadgetsRel is ListGadgets against
# gadgets_rel — same messages, same DTO seats, same handler, only the View name
# differs — so any difference observed here is the BACKING's, not the wire's.
# Connect protocol speaks plain JSON over POST, so curl is enough.
GRPC_BASE="${GRPC_BASE:-http://localhost:${GRPC_PORT:-9090}}"
grpc_total() { curl -sS -X POST -H "Content-Type: application/json" \
  "$GRPC_BASE/qafixtures.v1.QAService/$1" -d "$2" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); pi=d.get("pagination") or {}
  print(pi.get("totalCount","<absent>"), len(d.get("items") or []))
except Exception: print("<err> <err>")'; }

title "11.1 a paged gRPC list reports the FULL count, not the item count"
read -r ptot pitems <<<"$(grpc_total ListGadgetsRel '{"pagination":{"first":2}}')"
echo "grpc ListGadgetsRel(limit:2) → total=$ptot items=$pitems"
[ "$pitems" = "2" ] && [ "$ptot" = "3" ] && ok "gRPC PaginationInfo.total_count over a relational view = full count ($ptot over $pitems items)" || bad "gRPC relational total=$ptot items=$pitems (want 3 over 2)"

title "11.2 the gRPC only_total mode agrees with the paged list"
read -r ponly _ <<<"$(grpc_total ListGadgetsRel '{"pagination":{"only_total":true}}')"
[ "$ponly" = "$ptot" ] && ok "gRPC only_total agrees with the paged list ($ponly)" || bad "gRPC only_total=$ponly but the paged list said $ptot"

title "11.3 all THREE surfaces report one number for one view"
[ "$ptot" = "$gtot" ] && [ "$ptot" = "$rest_tot" ] && ok "REST=$rest_tot GraphQL=$gtot gRPC=$ptot — one view, one total" || bad "surface disagreement: REST=$rest_tot GraphQL=$gtot gRPC=$ptot"

##############################################################################
sec "12. The FULL reserved-control matrix on a relational view — all 3 surfaces"
##############################################################################
# Sections 10 and 11 proved ONE field (totalCount) reaches the non-REST surfaces.
# The rest of the reserved vocabulary was never exercised on this backing at all:
# no cursor walk, no envelope, no rejection matrix, no composite sort. That gap
# matters more here than on Mongo, because a RelationalSource view is a different
# READER (offset windows, a JOINed root SELECT) wearing the same wire contract —
# so parity is a claim about two implementations, not one.
#
# Active set at this point: GADGET-01/02/03 (04 was archived in 4.6). 01 and 02
# share category cat-a, which is the deliberate TIE the composite-sort cases need.
# ?search= stays a 400 here by design (section 5) — a capability limit of a root
# SELECT, not a bug, and the one control that must NOT reach parity.
RVB=$(mktemp)
rel_get() { local args=() p; for p in "$@"; do args+=(--data-urlencode "$p"); done
  RVS=$(curl -sS -o "$RVB" -w "%{http_code}" -G "$BASE/qa/rel/gadgets" "${args[@]}"); }
rvq()    { python3 -c "import sys,json; d=json.load(open('$RVB')); print($1)" 2>/dev/null; }
rv_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }
rv_400() { local l="$1"; shift; rel_get "$@"
  if [ "$RVS" = "400" ]; then ok "$l"; else bad "$l (got $RVS)"; head -c 160 "$RVB"; echo; fi; }

title "12.1 REST head page — endCursor emitted, startCursor NOT (edge-cursor rule)"
# The rule: an edge cursor exists only where its neighbour does. The relational
# reader used to emit BOTH on every non-empty page, so the head advertised a
# startCursor beside hasPreviousPage:false and the tail an endCursor beside
# hasNextPage:false. omitempty means an unemitted cursor is ABSENT, so presence
# IS the assertion — and this is the case that pins the fix on this backing.
rel_get "code.startswith=GADGET" "orderBy=code" "first=1"
rv_eq "head page is GADGET-01"        "$(rvq "d['data'][0]['code']")" "GADGET-01"
rv_eq "head hasNextPage"              "$(rvq "d['pagination']['hasNextPage']")" "True"
rv_eq "head hasPreviousPage false"    "$(rvq "d['pagination']['hasPreviousPage']")" "False"
rv_eq "head emits endCursor"          "$(rvq "'endCursor' in d['pagination']")" "True"
rv_eq "head OMITS startCursor"        "$(rvq "'startCursor' in d['pagination']")" "False"
RC1=$(rvq "d['pagination']['endCursor']")

title "12.2 REST page 2 — the window advances, both edges live"
rel_get "code.startswith=GADGET" "orderBy=code" "first=1" "after=$RC1"
rv_eq "page 2 is GADGET-02 (advanced)" "$(rvq "d['data'][0]['code']")" "GADGET-02"
rv_eq "page 2 hasPreviousPage"         "$(rvq "d['pagination']['hasPreviousPage']")" "True"
rv_eq "page 2 emits startCursor"       "$(rvq "'startCursor' in d['pagination']")" "True"
rv_eq "page 2 emits endCursor"         "$(rvq "'endCursor' in d['pagination']")" "True"
RC2S=$(rvq "d['pagination']['startCursor']"); RC2E=$(rvq "d['pagination']['endCursor']")

title "12.3 REST tail page — endCursor OMITTED beside hasNextPage:false"
rel_get "code.startswith=GADGET" "orderBy=code" "first=1" "after=$RC2E"
rv_eq "tail is GADGET-03"           "$(rvq "d['data'][0]['code']")" "GADGET-03"
rv_eq "tail hasNextPage false"      "$(rvq "d['pagination']['hasNextPage']")" "False"
rv_eq "tail OMITS endCursor"        "$(rvq "'endCursor' in d['pagination']")" "False"
rv_eq "tail still emits startCursor" "$(rvq "'startCursor' in d['pagination']")" "True"

title "12.4 REST ?last= alone (tail window) and ?before= (round trip)"
rel_get "code.startswith=GADGET" "orderBy=code" "last=1"
rv_eq "last=1 lands on GADGET-03" "$(rvq "d['data'][0]['code']")" "GADGET-03"
rel_get "code.startswith=GADGET" "orderBy=code" "last=1" "before=$RC2S"
rv_eq "before page-2 startCursor returns to GADGET-01" "$(rvq "d['data'][0]['code']")" "GADGET-01"

title "12.5 REST direction rule — all four mixes reject"
rv_400 "first+last"   "first=1" "last=1"
rv_400 "after+before" "after=$RC1" "before=$RC1"
rv_400 "last+after"   "last=1" "after=$RC1"
rv_400 "first+before" "first=1" "before=$RC1"

title "12.6 REST page size positivity, both directions"
rv_400 "first=0"  "first=0"
rv_400 "first=-5" "first=-5"
rv_400 "last=0"   "last=0"
rv_400 "last=-5"  "last=-5"

title "12.7 REST cursor shape + the three cursor↔context guards"
rv_400 "malformed cursor" "after=not-base64---"
rel_get "code.startswith=GADGET" "orderBy=code" "first=1"; RCTX=$(rvq "d['pagination']['endCursor']")
rv_400 "cursor↔filter mismatch"          "orderBy=code" "first=1" "after=$RCTX" "category.eq=cat-a"
rv_400 "cursor↔sort mismatch"            "code.startswith=GADGET" "first=1" "after=$RCTX"
rv_400 "cursor↔includeArchived mismatch" "code.startswith=GADGET" "orderBy=code" "first=1" "after=$RCTX" "includeArchived=true"

title "12.8 REST only-total conflict matrix — all six page-shaping keys"
rv_400 "onlyTotal+first"   "onlyTotal=true" "first=1"
rv_400 "onlyTotal+last"    "onlyTotal=true" "last=1"
rv_400 "onlyTotal+after"   "onlyTotal=true" "after=$RC1"
rv_400 "onlyTotal+before"  "onlyTotal=true" "before=$RC1"
rv_400 "onlyTotal+orderBy" "onlyTotal=true" "orderBy=code"
rv_400 "onlyTotal+fields"  "onlyTotal=true" "fields=code"

title "12.9 REST orderBy — COMPOSITE secondary key (cat-a tie) + invalid field"
# 01 and 02 both sit in cat-a, so only the SECOND term can order them: a reader
# that honored just the first term would look correct on every case above.
rel_get "category.eq=cat-a" "orderBy=category,code" "first=1"
rv_eq "composite [category,code] → GADGET-01"  "$(rvq "d['data'][0]['code']")" "GADGET-01"
rel_get "category.eq=cat-a" "orderBy=category,-code" "first=1"
rv_eq "composite [category,-code] → the secondary key FLIPS to GADGET-02" \
  "$(rvq "d['data'][0]['code']")" "GADGET-02"
rv_400 "orderBy=bogus" "orderBy=bogus"
rv_400 "fields=bogus"  "fields=bogus"

##############################################################################
# GraphQL over the SAME relational view. gql() is defined in section 10.
##############################################################################
gqlc() { gql "$1" | python3 -c "import sys,json
try:
  c=(json.load(sys.stdin).get('data') or {}).get('gadgetsRel') or {}
  print($2)
except Exception: print('<err>')"; }
# gqlk prints the first error's notificationKey, or "<untyped>" when the error
# carries none (a gqlparser SCHEMA validation error — e.g. an unknown argument —
# never reaches the framework's notification layer). "<none>" means the query
# was ACCEPTED. Rejection is "errors[] is non-empty", so an untyped validation
# error still counts: the case asserts the request was refused, and which layer
# refused it is not the subject here.
gqlk() { gql "$1" | python3 -c "import sys,json
d=json.load(sys.stdin); e=d.get('errors') or []
print(((e[0].get('extensions') or {}).get('notificationKey') or '<untyped>') if e else '<none>')"; }
gql_rej() { local l="$1" q="$2" k; k=$(gqlk "$q")
  if [ "$k" != "<none>" ]; then ok "$l (rejected: $k)"; else bad "$l (accepted — no error surfaced)"; fi; }
GPI='pageInfo { hasNextPage hasPreviousPage startCursor endCursor }'

title "12.10 GraphQL head page over the relational view — same edge-cursor rule"
Q="query { gadgetsRel(orderBy: [{field: CODE}], first: 1) { edges { cursor node { code } } $GPI } }"
rv_eq "GraphQL head is GADGET-01"     "$(gqlc "$Q" "c['edges'][0]['node']['code']")" "GADGET-01"
rv_eq "GraphQL head hasNextPage"      "$(gqlc "$Q" "c['pageInfo']['hasNextPage']")" "True"
rv_eq "GraphQL head startCursor null" "$(gqlc "$Q" "c['pageInfo']['startCursor'] is None")" "True"
rv_eq "GraphQL head endCursor set"    "$(gqlc "$Q" "c['pageInfo']['endCursor'] is not None")" "True"
GC1=$(gqlc "$Q" "c['pageInfo']['endCursor']")

title "12.11 GraphQL walk to the tail — endCursor goes null at the end"
Q2="query { gadgetsRel(orderBy: [{field: CODE}], first: 1, after: \"$GC1\") { edges { node { code } } $GPI } }"
rv_eq "GraphQL page 2 is GADGET-02"   "$(gqlc "$Q2" "c['edges'][0]['node']['code']")" "GADGET-02"
GC2E=$(gqlc "$Q2" "c['pageInfo']['endCursor']")
Q3="query { gadgetsRel(orderBy: [{field: CODE}], first: 1, after: \"$GC2E\") { edges { cursor node { code } } $GPI } }"
rv_eq "GraphQL tail is GADGET-03"        "$(gqlc "$Q3" "c['edges'][0]['node']['code']")" "GADGET-03"
rv_eq "GraphQL tail hasNextPage false"   "$(gqlc "$Q3" "c['pageInfo']['hasNextPage']")" "False"
rv_eq "GraphQL tail endCursor null"      "$(gqlc "$Q3" "c['pageInfo']['endCursor'] is None")" "True"
# edges[].cursor addresses ROWS, not boundaries — the final row keeps its cursor
# even though the page-level endCursor is gone. That distinction is the whole
# reason ItemCursors is not gated alongside the edges.
rv_eq "GraphQL tail row still carries edges[].cursor" \
  "$(gqlc "$Q3" "bool(c['edges'][0]['cursor'])")" "True"

title "12.12 GraphQL backward + rejection matrix on the relational view"
rv_eq "GraphQL last:1 is the tail (GADGET-03)" \
  "$(gqlc "query { gadgetsRel(orderBy: [{field: CODE}], last: 1) { edges { node { code } } } }" "c['edges'][0]['node']['code']")" "GADGET-03"
gql_rej "GraphQL first:0"        'query { gadgetsRel(first: 0) { edges { node { code } } } }'
gql_rej "GraphQL first:101 (ceiling)" 'query { gadgetsRel(first: 101) { edges { node { code } } } }'
gql_rej "GraphQL first+last"     'query { gadgetsRel(first: 1, last: 1) { edges { node { code } } } }'
gql_rej "GraphQL malformed cursor" 'query { gadgetsRel(first: 1, after: "not-base64---") { edges { node { code } } } }'
gql_rej "GraphQL search (unsupported on this backing)" 'query { gadgetsRel(search: "Alpha") { edges { node { code } } } }'

title "12.12b GraphQL cursor↔context guards on the relational view"
# The same three axes REST pins at 12.7. GraphQL has no pre-dispatch cursor
# check, so these come from the READER — which is exactly the path that used to
# answer 500 before the cursor rejections were typed.
gql_rej "GraphQL cursor↔filter mismatch" \
  "query { gadgetsRel(orderBy: [{field: CODE}], first: 1, after: \"$GC1\", where: { category: { eq: \"cat-a\" } }) { edges { node { code } } } }"
gql_rej "GraphQL cursor↔sort mismatch" \
  "query { gadgetsRel(first: 1, after: \"$GC1\") { edges { node { code } } } }"
gql_rej "GraphQL cursor↔includeArchived mismatch" \
  "query { gadgetsRel(orderBy: [{field: CODE}], first: 1, after: \"$GC1\", includeArchived: true) { edges { node { code } } } }"

title "12.12c GraphQL orderBy + includeArchived over the relational view"
rv_eq "GraphQL orderBy [-code] leads with GADGET-03" \
  "$(gqlc 'query { gadgetsRel(orderBy: [{field: CODE, direction: DESC}], first: 1) { edges { node { code } } } }' "c['edges'][0]['node']['code']")" "GADGET-03"
# cat-a holds GADGET-01 and GADGET-02, so only the SECOND term can order them.
rv_eq "GraphQL composite [category,code] → GADGET-01" \
  "$(gqlc 'query { gadgetsRel(where: { category: { eq: "cat-a" } }, orderBy: [{field: CATEGORY}, {field: CODE}], first: 1) { edges { node { code } } } }' "c['edges'][0]['node']['code']")" "GADGET-01"
rv_eq "GraphQL composite [category,-code] → the secondary key flips to GADGET-02" \
  "$(gqlc 'query { gadgetsRel(where: { category: { eq: "cat-a" } }, orderBy: [{field: CATEGORY}, {field: CODE, direction: DESC}], first: 1) { edges { node { code } } } }' "c['edges'][0]['node']['code']")" "GADGET-02"
gql_rej "GraphQL orderBy {field: BOGUS} (undeclared enum value)" 'query { gadgetsRel(orderBy: [{field: BOGUS}]) { edges { node { code } } } }'
# GADGET-04 was archived in 4.6: the default read hides it, the flag brings it back.
rv_eq "GraphQL default read hides the archived row (3)" \
  "$(gqlc 'query { gadgetsRel { totalCount } }' "c['totalCount']")" "3"
rv_eq "GraphQL includeArchived resurfaces it (4)" \
  "$(gqlc 'query { gadgetsRel(includeArchived: true) { totalCount } }' "c['totalCount']")" "4"

##############################################################################
# gRPC over the SAME relational view. Connect JSON omits false bools and empty
# strings, so on this surface ABSENCE is how an unemitted edge cursor reads.
##############################################################################
grpc_rel() { GRB=$(curl -sS -o /tmp/qa-relgrpc-${BACKEND}.json -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" "$GRPC_BASE/qafixtures.v1.QAService/ListGadgetsRel" -d "$1"); GRBODY=$(cat /tmp/qa-relgrpc-${BACKEND}.json); }
grpc_rej() { local l="$1"; grpc_rel "$2"
  if [ "$GRB" = "400" ]; then ok "$l"; else bad "$l (got $GRB: $(echo "$GRBODY" | head -c 140))"; fi; }

title "12.13 gRPC head/tail envelope over the relational view"
grpc_rel '{"orderBy":[{"field":"code"}],"pagination":{"first":1}}'
if echo "$GRBODY" | grep -q 'GADGET-01' && echo "$GRBODY" | grep -q '"hasNextPage":true' \
   && echo "$GRBODY" | grep -q '"endCursor"' && ! echo "$GRBODY" | grep -q '"startCursor"'; then
  ok "gRPC head: GADGET-01, endCursor present, startCursor absent"
else
  bad "gRPC head envelope"; echo "$GRBODY" | head -c 240; echo
fi
GRC1=$(echo "$GRBODY" | grep -o '"endCursor":"[^"]*"' | cut -d'"' -f4)
grpc_rel "{\"orderBy\":[{\"field\":\"code\"}],\"pagination\":{\"first\":1,\"after\":\"$GRC1\"}}"
GRC2=$(echo "$GRBODY" | grep -o '"endCursor":"[^"]*"' | cut -d'"' -f4)
grpc_rel "{\"orderBy\":[{\"field\":\"code\"}],\"pagination\":{\"first\":1,\"after\":\"$GRC2\"}}"
if echo "$GRBODY" | grep -q 'GADGET-03' && ! echo "$GRBODY" | grep -q 'hasNextPage' \
   && ! echo "$GRBODY" | grep -q '"endCursor"' && echo "$GRBODY" | grep -q '"startCursor"'; then
  ok "gRPC tail: GADGET-03, endCursor absent, startCursor present"
else
  bad "gRPC tail envelope"; echo "$GRBODY" | head -c 240; echo
fi

title "12.14 gRPC last-alone + rejection matrix on the relational view"
grpc_rel '{"orderBy":[{"field":"code"}],"pagination":{"last":1}}'
echo "$GRBODY" | grep -q 'GADGET-03' && ok "gRPC last:1 is the tail" || { bad "gRPC last:1"; echo "$GRBODY" | head -c 200; echo; }
grpc_rej "gRPC first:0"          '{"pagination":{"first":0}}'
grpc_rej "gRPC first:101 (ceiling)" '{"pagination":{"first":101}}'
grpc_rej "gRPC first+last"       '{"pagination":{"first":1,"last":1}}'
grpc_rej "gRPC after+before"     '{"pagination":{"after":"cur","before":"cur"}}'
grpc_rej "gRPC malformed cursor" '{"pagination":{"first":1,"after":"not-base64---"}}'
grpc_rej "gRPC onlyTotal+first"  '{"pagination":{"onlyTotal":true,"first":1}}'
grpc_rej "gRPC search (unsupported on this backing)" '{"pagination":{"search":"Alpha"}}'

title "12.15 gRPC cursor↔context guards on the relational view"
# GRC1 is the head cursor from 12.13 (orderBy code, no filter, default gate).
grpc_rej "gRPC cursor↔filter mismatch" \
  "{\"filters\":{\"category\":{\"conditions\":[{\"op\":\"STRING_OP_EQ\",\"values\":[\"cat-a\"]}]}},\"orderBy\":[{\"field\":\"code\"}],\"pagination\":{\"first\":1,\"after\":\"$GRC1\"}}"
grpc_rej "gRPC cursor↔orderBy mismatch" \
  "{\"pagination\":{\"first\":1,\"after\":\"$GRC1\"}}"
grpc_rej "gRPC cursor↔include_archived mismatch" \
  "{\"orderBy\":[{\"field\":\"code\"}],\"pagination\":{\"first\":1,\"after\":\"$GRC1\",\"includeArchived\":true}}"

title "12.16 gRPC orderBy, include_archived and fields over the relational view"
grpc_rel '{"orderBy":[{"field":"code","desc":true}],"pagination":{"first":1}}'
echo "$GRBODY" | grep -q 'GADGET-03' && ok "gRPC orderBy desc leads with GADGET-03" || { bad "gRPC orderBy desc"; echo "$GRBODY" | head -c 200; echo; }
# cat-a ties GADGET-01/02 on the first term, so the second term is the only
# thing that can order them — the multi-term leg a single-key case cannot prove.
grpc_rel '{"filters":{"category":{"conditions":[{"op":"STRING_OP_EQ","values":["cat-a"]}]}},"orderBy":[{"field":"category"},{"field":"code"}],"pagination":{"first":1}}'
echo "$GRBODY" | grep -q 'GADGET-01' && ok "gRPC composite [category,code] → GADGET-01" || { bad "gRPC composite asc"; echo "$GRBODY" | head -c 200; echo; }
grpc_rel '{"filters":{"category":{"conditions":[{"op":"STRING_OP_EQ","values":["cat-a"]}]}},"orderBy":[{"field":"category"},{"field":"code","desc":true}],"pagination":{"first":1}}'
echo "$GRBODY" | grep -q 'GADGET-02' && ok "gRPC composite [category,-code] → secondary key flips to GADGET-02" || { bad "gRPC composite desc"; echo "$GRBODY" | head -c 200; echo; }
grpc_rej "gRPC orderBy bogus" '{"orderBy":[{"field":"bogus"}]}'
grpc_rej "gRPC fields bogus"  '{"fields":"bogus"}'
# include_archived must reshape the ITEMS, not only the count (GADGET-04 was
# archived in 4.6).
grpc_rel '{"orderBy":[{"field":"code"}],"pagination":{"first":10}}'
! echo "$GRBODY" | grep -q 'GADGET-04' && ok "gRPC default read hides the archived row" || { bad "gRPC default read leaked GADGET-04"; echo "$GRBODY" | head -c 200; echo; }
grpc_rel '{"orderBy":[{"field":"code"}],"pagination":{"first":10,"includeArchived":true}}'
echo "$GRBODY" | grep -q 'GADGET-04' && ok "gRPC include_archived surfaces it IN THE ITEMS" || { bad "gRPC include_archived items"; echo "$GRBODY" | head -c 200; echo; }
# The fields mask projects: asking for code alone must drop the other leaves.
grpc_rel '{"fields":"code","orderBy":[{"field":"code"}],"pagination":{"first":1}}'
if echo "$GRBODY" | grep -q 'GADGET-01' && ! echo "$GRBODY" | grep -q '"category"'; then
  ok "gRPC fields mask projects (category masked out)"
else
  bad "gRPC fields projection"; echo "$GRBODY" | head -c 200; echo
fi

rm -f "$RVB"

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
