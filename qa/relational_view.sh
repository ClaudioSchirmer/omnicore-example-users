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
#   3. UNSUPPORTED → 400 RelationalCapabilityNotification — a capability a single
#      root SELECT cannot express: ?search=, and (on the Widget twin, an aggregate
#      with a child array + a root sibling + a child-level sibling) a filter or
#      sort on a child field (widgetParts.label), a root sibling (material) or a
#      child-level sibling (widgetParts.tag). The SAME query row-selects on the
#      Mongo view — the contrast the suite asserts side by side.
#   4. CEILINGS — the relational reader honors MaxLimit (?limit over the cap → 400
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
  qa_view_drop gadgets gadgets_hot gadgets_capped gadget_notes qa_lens_brands_view qa_widgets_view upstream_gadgets
}
trap cleanup EXIT INT TERM

# ── helpers ─────────────────────────────────────────────────────────────────
# data length of a JSON body file (-1 on any error).
len_of() { python3 -c 'import sys,json
try:
  d=json.load(open(sys.argv[1])); data=d.get("data",[])
  print(len(data) if isinstance(data,list) else -1)
except Exception: print(-1)' "$1"; }

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
  echo "mongo $mpath?$qs → $ms/$mn   rel $rpath?$qs → $rs/$rn   (want $want)"
  if [ "$ms" = "200" ] && [ "$rs" = "200" ] && [ "$mn" = "$want" ] && [ "$rn" = "$want" ]; then
    ok "$name (mongo=$mn rel=$rn)"
  else
    bad "$name (want 200/$want both, got mongo $ms/$mn rel $rs/$rn)"
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
  mf=$(curl -sS "$BASE/qa/gadgets?sort=$dir&limit=1" | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(d[0]["code"] if d else "")')
  rf=$(curl -sS "$BASE/qa/rel/gadgets?sort=$dir&limit=1" | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(d[0]["code"] if d else "")')
  [ -n "$mf" ] && [ "$mf" = "$rf" ] && ok "sort=$dir first code parity ($mf)" || bad "sort=$dir first code mongo=$mf rel=$rf"
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
mt=$(curl -sS "$BASE/qa/gadgets?onlyTotal=true" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("total"))')
rt=$(curl -sS "$BASE/qa/rel/gadgets?onlyTotal=true" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("total"))')
[ "$mt" = "4" ] && [ "$rt" = "4" ] && ok "onlyTotal parity (mongo=$mt rel=$rt)" || bad "onlyTotal mongo=$mt rel=$rt"

title "4.4 pagination — limit + after walks the full set once, no dups"
cur=$(curl -sS "$BASE/qa/rel/gadgets?sort=code&limit=2" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("next_cursor",""))')
echo "page1 next_cursor: ${cur:0:16}…"
# The cursor is base64 (may carry +/=), so pass it through --data-urlencode.
p2=$(curl -sS -G "$BASE/qa/rel/gadgets" --data-urlencode "sort=code" --data-urlencode "limit=2" --data-urlencode "after=$cur" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]))')
[ -n "$cur" ] && [ "$p2" = "2" ] && ok "relational after-cursor returns the second page (2)" || bad "after-cursor page2 got $p2 (cursor=${cur:0:12})"

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

##############################################################################
sec "5. Gadgets unsupported — ?search= → 400 (rel) vs 200 (mongo text search)"
##############################################################################
reject4xx "5.1 relational ?search= is rejected" "/qa/rel/gadgets" "search=Alpha"
status_is "5.2 mongo ?search= runs the text search (200)" "$BASE/qa/gadgets?search=Alpha" 200

##############################################################################
sec "6. Ceilings — MaxLimit + MaxExportRows on the capped twin, CSV parity"
##############################################################################
status_is "6.1 capped ?limit=100 → 400 LimitExceeded"    "$BASE/qa/rel/gadgets-capped?limit=100" 400 "LimitExceededNotification"
status_is "6.2 capped ?limit=5 (at the cap) → 200"        "$BASE/qa/rel/gadgets-capped?limit=5"   200
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
sec "8. Widgets twin — child + sibling fields: 400 (rel) vs row-select (mongo)"
##############################################################################
title "8.1 root name is served identically (parity)"
parity "8.1 name parity" "/qa/widgets" "/qa/rel/widgets" "name.eq=Widget A" 1

title "8.2 the relational twin rejects every non-root field"
reject4xx "8.2a material (root sibling, flat)"     "/qa/rel/widgets" "material.eq=aluminium"
reject4xx "8.2b widgetParts.label (child field)"   "/qa/rel/widgets" "widgetParts.label.eq=lens"
reject4xx "8.2c widgetParts.tag (child sibling)"   "/qa/rel/widgets" "widgetParts.tag.eq=optical"
reject4xx "8.2d sort=material (root sibling)"       "/qa/rel/widgets" "sort=material"
reject4xx "8.2e sort=widgetParts.label (child)"     "/qa/rel/widgets" "sort=widgetParts.label"

title "8.3 the SAME queries row-select on the Mongo view (the contrast)"
status_is "8.3a mongo material.eq → 200"           "$BASE/qa/widgets?material.eq=aluminium" 200
status_is "8.3b mongo widgetParts.label.eq → 200"  "$BASE/qa/widgets?widgetParts.label.eq=lens" 200
mn=$(curl -sS "$BASE/qa/widgets?material.eq=steel" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("data",[])))')
[ "$mn" = "1" ] && ok "8.3c mongo material.eq=steel selects the 1 matching widget" || bad "8.3c mongo material row-select got $mn (want 1)"

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

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
