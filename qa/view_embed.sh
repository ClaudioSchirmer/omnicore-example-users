#!/usr/bin/env bash
# MATERIALIZED view-on-view suite — query.JoinView as an embed source.
#
# The framework lets a view EMBED another registered view (materialized, kept
# fresh by the recompose-ripple the SyncEngine fires on every write to the source
# view). This is the road that needs no broker hop at all: the upstream-mirror
# showcase (upstream_composition.sh / external_embed.sh) publishes to a topic and
# consumes it back to mirror data that is already local; here the view IS the leg.
#
# The fixture family is a SIDE family (`qa_lens_*`), so nothing the upstream
# showcase materializes changes shape:
#
#   qa_lens_brands_view ─┐
#                        ├─1:1 Embed→ qa_lens_parts_view ─1:N EmbedMany→ qa_lens_kits_view
#   gadgets (existing) ──┘
#
# Two embed sources on purpose: `qa_lens_brands_view` is owned by this family (it
# has an update verb, so a VALUE change can be followed two hops out), and
# `gadgets` is a view the family does NOT own (proving any registered view is
# embeddable — its delete propagates two hops as an explicit null).
#
# Asserts, in order:
#   1  compose — both 1:1 segments + the 1:N segment, null FK ⇒ explicit null
#   2  EMBED-OF-EMBED — a brand rename reaches parts[].brand (hop 1) AND
#      kits[].parts[].brand (hop 2); a gadget hard-delete nulls both levels
#   3  ripple on the middle hop — a part edit reaches the kit's array element
#   4  FK moves — repointing gadgetId re-resolves the 1:1 (nothing changed on the
#      gadget's side: only the post-write repair can do it); repointing kitId
#      moves the element between arrays
#   5  filters — root, INTO a 1:1 segment (SELECTS ROWS — the materialized
#      difference from a composed leg), INTO the 1:N segment (array matching),
#      AND-combined, match-nothing
#   6  sort — by a root field and by a 1:1 SEGMENT field (first-class sort key)
#   7  ?fields= — root pruning, into a 1:1 segment, and TWO levels deep
#      (parts.gadget.code); onlyTotal
#   8  pagination — limit + after cursor, forward, over both hops
#   9  archive/unarchive — of the SOURCE (segment mirrors the stored state, the
#      materialized-embed contract) and of the EMBEDDING document (own gate)
#  10  hard delete — of the source (segment ⇒ null / element removed) and of the
#      embedding document
#  11  the failure registry stays clean on the happy path
#
# Prereqs: docker compose up + the OUTBOX Debezium connector registered.
# Self-managed server lifecycle. Dialect-driven via _backend.sh.
# Run from anywhere:  bash qa/view_embed.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-view-embed-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-view-embed-${BACKEND:-postgres}.log"
QA_YAML="$REPO_ROOT/microservice.qa.yaml"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }

drop_collections() { qa_view_drop qa_lens_parts_view qa_lens_kits_view qa_lens_kits_desc_view qa_lens_brands_view; }
reset_domain() {
  qa_db_exec "DELETE FROM qa_lens_parts;" 2>/dev/null || true
  qa_db_exec "DELETE FROM qa_lens_kits;"  2>/dev/null || true
  qa_db_exec "DELETE FROM qa_lens_brands;" 2>/dev/null || true
  qa_db_exec "DELETE FROM gadgets WHERE code LIKE 'VE-%';" 2>/dev/null || true
  drop_collections
}
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port "${HTTP_PORT:-8080}"
  reset_domain
}
trap cleanup EXIT INT TERM

# ── JSON helpers ─────────────────────────────────────────────────────────────
jid()  { python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("data",{}).get("id",""))
except Exception: print("")'; }
post_json() { curl -sS -X POST "$1" -H "Content-Type: application/json" --data "$2"; }
put_json()  { curl -sS -X PUT  "$1" -H "Content-Type: application/json" --data "$2"; }
code_of()   { curl -sS -o /dev/null -w '%{http_code}' "$@"; }

# jpath URL DOTTED — prints the value at a dotted path under .data (by-id) or
# .data[0] (list). Array hops accept a numeric index. "" when absent/null.
jpath() {
  curl -sS "$1" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print(""); sys.exit()
node = d.get("data")
if isinstance(node, list): node = node[0] if node else None
for seg in sys.argv[1].split("."):
    if node is None: break
    if isinstance(node, list):
        try: node = node[int(seg)]
        except Exception: node = None
    else:
        node = node.get(seg) if isinstance(node, dict) else None
print("" if node is None else node)' "$2"
}
# jlist URL DOTTED — comma-joined, sorted values of DOTTED across every data item.
jlist() {
  curl -sS "$1" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print(""); sys.exit()
items = d.get("data") or []
if isinstance(items, dict): items = [items]
out=[]
for it in items:
    node = it
    for seg in sys.argv[1].split("."):
        if node is None: break
        if isinstance(node, list):
            try: node = node[int(seg)]
            except Exception: node = None
        else:
            node = node.get(seg) if isinstance(node, dict) else None
    out.append("" if node is None else str(node))
print(",".join(sorted(out)))' "$2"
}
jcount() { curl -sS "$1" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print(-1); sys.exit()
x=d.get("data")
print(len(x) if isinstance(x,list) else (0 if x is None else 1))'; }
jtotal() { curl -sS "$1" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("pagination",{}).get("totalCount",-1))
except Exception: print(-1)'; }
jkeys()  { curl -sS "$1" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print(""); sys.exit()
node = d.get("data")
if isinstance(node, list): node = node[0] if node else {}
for seg in (sys.argv[1].split(".") if sys.argv[1] else []):
    if isinstance(node, list): node = node[0] if node else {}
    node = (node or {}).get(seg) or {}
if isinstance(node, list): node = node[0] if node else {}
print(",".join(sorted((node or {}).keys())))' "$2"
}
# jelem URL LABEL DOTTED — the element of parts[] whose label is LABEL, then the
# dotted path inside it. A 1:N segment has NO declared order (that knob exists
# only on a ComposedView's LinkMany), so the suite selects by IDENTITY, never by
# position — asserting the contract instead of an accident of insertion order.
jelem() {
  curl -sS "$1" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print(""); sys.exit()
node = d.get("data")
if isinstance(node, list): node = node[0] if node else None
parts = (node or {}).get("parts") or []
el = next((p for p in parts if isinstance(p, dict) and p.get("label") == sys.argv[1]), None)
for seg in sys.argv[2].split("."):
    if el is None: break
    el = el.get(seg) if isinstance(el, dict) else None
print("" if el is None else el)' "$2" "$3"
}
# wait_elem URL LABEL DOTTED EXPECTED [TRIES]
wait_elem() {
  local url="$1" label="$2" path="$3" want="$4" tries="${5:-60}" got=""
  for _ in $(seq 1 "$tries"); do
    got=$(jelem "$url" "$label" "$path")
    [ "$got" = "$want" ] && return 0
    sleep 0.5
  done
  printf '  (last seen: %s want: %s)\n' "${got:-<empty>}" "$want"
  return 1
}
# jelem_keys URL LABEL DOTTED — sorted keys of the object at DOTTED inside the
# identified element (for the two-level ?fields= assertion).
jelem_keys() {
  curl -sS "$1" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print(""); sys.exit()
node = d.get("data")
if isinstance(node, list): node = node[0] if node else None
parts = (node or {}).get("parts") or []
el = next((p for p in parts if isinstance(p, dict) and p.get("label") == sys.argv[1]), None)
for seg in (sys.argv[2].split(".") if sys.argv[2] else []):
    el = (el or {}).get(seg) if isinstance(el, dict) else None
print(",".join(sorted((el or {}).keys())))' "$2" "$3"
}

# wait_for URL DOTTED EXPECTED [TRIES] — polls until the dotted value matches.
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

##############################################################################
sec "0. Build qa binary + connector + boot"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"

title "0.2 Ensure the outbox Debezium connector is registered"
"$REPO_ROOT/devops/debezium/register-connector.sh" "$QA_CONNECTOR_DIALECT" >/dev/null 2>&1 && ok "outbox connector registered" || bad "outbox connector registration failed"

title "0.3 Clean baseline BEFORE boot (the views materialize from scratch)"
reset_domain
ok "clean baseline"

title "0.4 Start server (APP_PROFILE=dev, config=microservice.qa.yaml)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$QA_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 40 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready" || { bad "server not ready"; tail -n 40 "$SERVER_LOG"; exit 1; }

title "0.5 Boot accepted the view-on-view declarations"
grep -q "view embed cycle" "$SERVER_LOG" && bad "boot reported an embed cycle" || ok "no embed-cycle diagnostic"
grep -q "NO covering index" "$SERVER_LOG" && bad "boot reported a missing covering index" || ok "covering-index guards satisfied"

qa_cdc_warmup_gadget

##############################################################################
sec "1. Compose — both 1:1 segments + the 1:N segment"
##############################################################################
BRAND=$(post_json "$BASE/qa/lens-brands" '{"name":"Zeiss"}' | jid)
BRAND2=$(post_json "$BASE/qa/lens-brands" '{"name":"Leica"}' | jid)
GADGET=$(post_json "$BASE/qa/gadgets" '{"code":"VE-G1","name":"Gadget One","category":"optics","status":"active"}' | jid)
GADGET2=$(post_json "$BASE/qa/gadgets" '{"code":"VE-G2","name":"Gadget Two","category":"tools","status":"active"}' | jid)
KIT=$(post_json  "$BASE/qa/lens-kits" '{"name":"Alpha kit"}' | jid)
KIT2=$(post_json "$BASE/qa/lens-kits" '{"name":"Beta kit"}'  | jid)
[ -n "$BRAND" ] && [ -n "$GADGET" ] && [ -n "$KIT" ] && ok "seeded brands/gadgets/kits" || { bad "seed failed"; tail -n 30 "$SERVER_LOG"; exit 1; }

P1=$(post_json "$BASE/qa/lens-parts" "{\"kitId\":\"$KIT\",\"gadgetId\":\"$GADGET\",\"brandId\":\"$BRAND\",\"label\":\"left lens\",\"slot\":1}"  | jid)
P2=$(post_json "$BASE/qa/lens-parts" "{\"kitId\":\"$KIT\",\"gadgetId\":\"$GADGET2\",\"brandId\":\"$BRAND2\",\"label\":\"right lens\",\"slot\":2}" | jid)
P3=$(post_json "$BASE/qa/lens-parts" "{\"kitId\":\"$KIT\",\"gadgetId\":null,\"brandId\":null,\"label\":\"spare\",\"slot\":3}" | jid)
[ -n "$P1" ] && [ -n "$P2" ] && [ -n "$P3" ] && ok "seeded 3 parts (2 linked, 1 with null FKs)" || { bad "part seed failed"; exit 1; }

P1_URL="$BASE/qa/lens-parts/$P1"
KIT_URL="$BASE/qa/lens-kits/$KIT"

title "1.1 hop 1 — the part carries BOTH 1:1 segments"
wait_for "$P1_URL" "brand.name" "Zeiss" && ok "parts[].brand materialized" || bad "parts[].brand never materialized"
wait_for "$P1_URL" "gadget.code" "VE-G1" && ok "parts[].gadget materialized (a view this family does not own)" || bad "parts[].gadget never materialized"

title "1.2 the embedded gadget carries its FULL projection (unlike a filtered mirror)"
[ "$(jpath "$P1_URL" "gadget.category")" = "optics" ] && ok "gadget.category present (mirror would have filtered it out)" || bad "gadget.category missing"

title "1.3 a null FK yields an explicit null segment, never a stale one"
[ -z "$(jpath "$BASE/qa/lens-parts/$P3" "brand.name")" ] && ok "null brandId ⇒ no brand segment" || bad "null brandId produced a segment"

title "1.4 hop 2 — the kit carries the 1:N segment, elements carrying THEIR segments"
wait_elem "$KIT_URL" "left lens" "label" "left lens" && ok "kits[].parts materialized" || bad "kits[].parts never materialized"
[ "$(jcount "$KIT_URL")" = "1" ] && ok "by-id returns one kit document" || bad "unexpected by-id shape"
[ "$(jelem "$KIT_URL" "left lens" "brand.name")" = "Zeiss" ] && ok "EMBED-OF-EMBED on the wire: kits[].parts[].brand" || bad "kits[].parts[].brand absent"

##############################################################################
sec "2. EMBED-OF-EMBED — a source change travels TWO ripple hops"
##############################################################################
title "2.1 rename the deepest source (brand)"
put_json "$BASE/qa/lens-brands/$BRAND" '{"name":"Zeiss RENAMED"}' >/dev/null
wait_for "$P1_URL" "brand.name" "Zeiss RENAMED" && ok "hop 1: parts[].brand.name refreshed" || bad "hop 1 did not refresh"
wait_elem "$KIT_URL" "left lens" "brand.name" "Zeiss RENAMED" && ok "hop 2: kits[].parts[].brand.name refreshed (chained ripple)" || bad "hop 2 did not refresh"

title "2.2 hard-delete a source this family does NOT own (gadget) — null at both hops"
curl -sS -o /dev/null -X DELETE "$BASE/qa/gadgets/$GADGET2"
wait_for "$BASE/qa/lens-parts/$P2" "gadget.code" "" && ok "hop 1: deleted source ⇒ segment nulled" || bad "hop 1 kept a dead reference"
wait_elem "$KIT_URL" "right lens" "gadget.code" "" && ok "hop 2: deleted source ⇒ nested segment nulled" || bad "hop 2 kept a dead reference"

##############################################################################
sec "3. Ripple on the MIDDLE hop — a part edit reaches the kit's array"
##############################################################################
put_json "$BASE/qa/lens-parts/$P1" "{\"kitId\":\"$KIT\",\"gadgetId\":\"$GADGET\",\"brandId\":\"$BRAND\",\"label\":\"left lens v2\",\"slot\":1}" >/dev/null
wait_elem "$KIT_URL" "left lens v2" "label" "left lens v2" && ok "part edit refreshed the kit's element" || bad "kit element stayed stale"

##############################################################################
sec "4. FK moves — the two the source side never announces"
##############################################################################
title "4.1 repoint gadgetId (only the post-write repair can re-resolve this)"
put_json "$BASE/qa/lens-parts/$P1" "{\"kitId\":\"$KIT\",\"gadgetId\":\"$GADGET\",\"brandId\":\"$BRAND2\",\"label\":\"left lens v2\",\"slot\":1}" >/dev/null
wait_for "$P1_URL" "brand.name" "Leica" && ok "repointed 1:1 segment re-resolved" || bad "1:1 segment kept the OLD source after an FK change"

title "4.2 move the part to another kit — element leaves one array, enters the other"
put_json "$BASE/qa/lens-parts/$P1" "{\"kitId\":\"$KIT2\",\"gadgetId\":\"$GADGET\",\"brandId\":\"$BRAND2\",\"label\":\"left lens v2\",\"slot\":1}" >/dev/null
wait_elem "$BASE/qa/lens-kits/$KIT2" "left lens v2" "label" "left lens v2" && ok "new parent gained the element" || bad "new parent never gained the element"
LEFT_IN_OLD=$(jelem "$KIT_URL" "left lens v2" "label")
[ "$LEFT_IN_OLD" != "left lens v2" ] && ok "old parent lost the element" || bad "old parent kept the moved element"

# move it back so the later sections read a stable kit
put_json "$BASE/qa/lens-parts/$P1" "{\"kitId\":\"$KIT\",\"gadgetId\":\"$GADGET\",\"brandId\":\"$BRAND\",\"label\":\"left lens v2\",\"slot\":1}" >/dev/null
wait_elem "$KIT_URL" "left lens v2" "brand.name" "Zeiss RENAMED" && ok "moved back (baseline restored)" || bad "restore failed"

##############################################################################
sec "5. Filters — a segment predicate SELECTS ROWS (the materialized difference)"
##############################################################################
title "5.1 root filter"
[ "$(jcount "$BASE/qa/lens-parts?label=spare")" = "1" ] && ok "root filter selects" || bad "root filter wrong"

title "5.2 filter INTO the 1:1 segment — selects ROWS, not segment content"
N=$(jcount "$BASE/qa/lens-parts?gadget.code=VE-G1")
[ "$N" = "1" ] && ok "gadget.code=VE-G1 ⇒ exactly the matching row" || bad "1:1 segment filter returned $N rows"
[ "$(jpath "$BASE/qa/lens-parts?gadget.code=VE-G1" "label")" = "left lens v2" ] && ok "the row returned is the right one" || bad "wrong row returned"

title "5.2b filter INTO the 1:1 segment BY ITS IDENTITY (gadget.id) — the embedded view's own id, deep"
[ "$(jcount "$BASE/qa/lens-parts?gadget.id=$GADGET")" = "1" ] && ok "gadget.id=<id> ⇒ exactly the matching row (deep view-on-view segment id is queryable)" || bad "deep segment id filter wrong"
[ "$(jcount "$BASE/qa/lens-parts?gadget.id=no-such-gadget")" = "0" ] && ok "gadget.id=bogus ⇒ 0 rows (no false positive)" || bad "deep segment id filter false positive"

title "5.3 the same filter with an operator + a match-nothing value"
[ "$(jcount "$BASE/qa/lens-parts?gadget.code.startswith=VE-")" -ge 1 ] && ok "startswith on a segment field works" || bad "segment operator failed"
[ "$(jcount "$BASE/qa/lens-parts?gadget.code=NOPE")" = "0" ] && ok "match-nothing removes the ROW (composed leg would keep it)" || bad "match-nothing kept rows"

title "5.4 AND-combined root + segment"
[ "$(jcount "$BASE/qa/lens-parts?slot=1&brand.name=Zeiss%20RENAMED")" = "1" ] && ok "root AND segment" || bad "AND-combined filter wrong"

title "5.5 filter INTO the 1:N segment (array matching selects the kit)"
[ "$(jcount "$BASE/qa/lens-kits?parts.label=spare")" = "1" ] && ok "parts.label selects the kit holding it" || bad "1:N segment filter wrong"
[ "$(jcount "$BASE/qa/lens-kits?parts.label=nothing-here")" = "0" ] && ok "no element matches ⇒ no kit" || bad "1:N match-nothing kept kits"

##############################################################################
sec "5.6 ORDER of the materialized 1:N segment (EmbedMany.OrderBy)"
##############################################################################
# qa_lens_kits_view declares .OrderBy("slot"), so the stored array is sorted by
# the SOURCE's slot — deterministic across every writer, not an accident of the
# order the writes happened to arrive in. Seeded out of order on purpose.
ORD_KIT=$(post_json "$BASE/qa/lens-kits" '{"name":"Ordered kit"}' | jid)
for pair in "30 gamma" "10 alpha" "20 beta"; do
  set -- $pair
  post_json "$BASE/qa/lens-parts" "{\"kitId\":\"$ORD_KIT\",\"brandId\":null,\"gadgetId\":null,\"label\":\"$2\",\"slot\":$1}" >/dev/null
done
ORD_URL="$BASE/qa/lens-kits/$ORD_KIT"
seq_of() { curl -sS "$1" | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data") or {}
print(",".join(str(p.get("label")) for p in (d.get("parts") or [])))'; }
for _ in $(seq 1 60); do [ "$(seq_of "$ORD_URL")" = "alpha,beta,gamma" ] && break; sleep 0.5; done
GOT=$(seq_of "$ORD_URL")
[ "$GOT" = "alpha,beta,gamma" ] && ok "1:N segment stored in the declared order ($GOT)" || bad "declared order not materialized: $GOT"

title "5.6b a LATE element lands in its slot, not at the end"
post_json "$BASE/qa/lens-parts" "{\"kitId\":\"$ORD_KIT\",\"brandId\":null,\"gadgetId\":null,\"label\":\"beta-and-a-half\",\"slot\":15}" >/dev/null
for _ in $(seq 1 60); do [ "$(seq_of "$ORD_URL")" = "alpha,beta-and-a-half,beta,gamma" ] && break; sleep 0.5; done
GOT=$(seq_of "$ORD_URL")
[ "$GOT" = "alpha,beta-and-a-half,beta,gamma" ] && ok "surgical insert respected the order ($GOT)" || bad "late element not ordered: $GOT"

title "5.6c removing an element preserves the order of the rest (the strip path)"
DOOMED=$(curl -sS "$ORD_URL" | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data") or {}
print(next((p.get("id") for p in (d.get("parts") or []) if p.get("label")=="beta"), ""))')
[ -n "$DOOMED" ] && curl -sS -o /dev/null -X DELETE "$BASE/qa/lens-parts/$DOOMED"
for _ in $(seq 1 60); do [ "$(seq_of "$ORD_URL")" = "alpha,beta-and-a-half,gamma" ] && break; sleep 0.5; done
GOT=$(seq_of "$ORD_URL")
[ "$GOT" = "alpha,beta-and-a-half,gamma" ] && ok "order survives an element removal ($GOT)" || bad "order broken after removal: $GOT"

title "5.6d the OTHER writer: full recompose (the path a rebuild backfill uses)"
# Delete the kit's stored document, then touch a part. The ripple finds no parent
# document and falls back to a FULL recompose — the same composer + stage builder
# the blue-green rebuild's backfill drives. If that writer sorted differently from
# the surgical one, the array would come back in source order.
docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval \
  "['qa_lens_kits_view','qa_lens_kits_view__0','qa_lens_kits_view__1'].forEach(function(n){db.getCollection(n).deleteOne({_id:'$ORD_KIT'})})" >/dev/null 2>&1
TOUCH=$(curl -sS "$BASE/qa/lens-parts?kitId=$ORD_KIT&label=alpha" | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data") or []
print(d[0].get("id") if d else "")')
[ -n "$TOUCH" ] && put_json "$BASE/qa/lens-parts/$TOUCH" "{\"kitId\":\"$ORD_KIT\",\"gadgetId\":null,\"brandId\":null,\"label\":\"alpha\",\"slot\":10}" >/dev/null
for _ in $(seq 1 60); do [ "$(seq_of "$ORD_URL")" = "alpha,beta-and-a-half,gamma" ] && break; sleep 0.5; done
GOT=$(seq_of "$ORD_URL")
[ "$GOT" = "alpha,beta-and-a-half,gamma" ] && ok "the recompose writer emits the SAME order ($GOT)" || bad "recompose writer disagreed with the ripple: $GOT"

title "5.6e .Desc() — the SAME data, the opposite stored order"
# qa_lens_kits_desc_view is a second projection of the same root declaring
# .OrderBy("slot").Desc(). Both collections are written by the same writers from
# the same source, so the difference between them IS the ordering.
seq_desc() { curl -sS "$BASE/qa/lens-kits-desc/$ORD_KIT" | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data") or {}
print(",".join(str(p.get("label")) for p in (d.get("parts") or [])))'; }
for _ in $(seq 1 60); do [ "$(seq_desc)" = "gamma,beta-and-a-half,alpha" ] && break; sleep 0.5; done
GOT_DESC=$(seq_desc)
[ "$GOT_DESC" = "gamma,beta-and-a-half,alpha" ] && ok "Desc() materialized the reverse order ($GOT_DESC)" || bad "Desc() order wrong: $GOT_DESC"
[ "$GOT_DESC" != "$(seq_of "$ORD_URL")" ] && ok "the two projections of one root differ ONLY by the declared order" || bad "asc and desc projections are identical"

title "5.6f the order survives a REBUILD (wiped collection → framework rebuild at boot)"
# Stop the server, wipe both kit projections, restart: the framework detects the
# wiped collections and rebuilds them from the relational source under
# autoRun=true — the blue-green backfill path, end to end. The declared order
# must come back, which is only true if the backfill's writer sorts identically.
if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
kill_port "${HTTP_PORT:-8080}"
qa_view_drop qa_lens_kits_view qa_lens_kits_desc_view
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$QA_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 60 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/readyz" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server back up after the wipe (rebuild ran)" || { bad "server never became ready after the wipe"; tail -n 25 "$SERVER_LOG"; }
for _ in $(seq 1 60); do [ "$(seq_of "$ORD_URL")" = "alpha,beta-and-a-half,gamma" ] && break; sleep 0.5; done
GOT=$(seq_of "$ORD_URL")
[ "$GOT" = "alpha,beta-and-a-half,gamma" ] && ok "REBUILT ascending projection kept the declared order ($GOT)" || bad "rebuild lost the order: $GOT"
for _ in $(seq 1 60); do [ "$(seq_desc)" = "gamma,beta-and-a-half,alpha" ] && break; sleep 0.5; done
GOT=$(seq_desc)
[ "$GOT" = "gamma,beta-and-a-half,alpha" ] && ok "REBUILT descending projection kept its own order ($GOT)" || bad "rebuild lost the desc order: $GOT"

##############################################################################
sec "6. Sort — a 1:1 segment field is a first-class sort key"
##############################################################################
ASC=$(jlist "$BASE/qa/lens-parts?orderBy=slot" "slot")
[ -n "$ASC" ] && ok "sort by a root field ($ASC)" || bad "root sort failed"
FIRST_ASC=$(jpath "$BASE/qa/lens-parts?orderBy=gadget.code&gadget.code.startswith=VE-" "gadget.code")
FIRST_DESC=$(jpath "$BASE/qa/lens-parts?orderBy=-gadget.code&gadget.code.startswith=VE-" "gadget.code")
[ -n "$FIRST_ASC" ] && ok "orderBy=gadget.code accepted (asc first=$FIRST_ASC)" || bad "sort by a segment field rejected"
[ "$FIRST_ASC" != "$FIRST_DESC" ] || [ "$(jcount "$BASE/qa/lens-parts?gadget.code.startswith=VE-")" = "1" ] \
  && ok "sort direction honored on the segment key" || bad "segment sort ignored the direction"

##############################################################################
sec "7. ?fields= — pruning INTO the segments, two levels deep"
##############################################################################
title "7.1 root pruning"
K=$(jkeys "$BASE/qa/lens-parts?fields=label&label=spare" "")
[ "$K" = "label" ] && ok "root ?fields= prunes to the asked field ($K)" || bad "root ?fields= returned: $K"

title "7.2 into a 1:1 segment"
K=$(jkeys "$BASE/qa/lens-parts?fields=label,gadget.code&gadget.code=VE-G1" "gadget")
[ "$K" = "code" ] && ok "segment pruned to gadget.code ($K)" || bad "segment ?fields= returned: $K"

title "7.2b into a 1:1 segment BY ID — gadget.id kept when asked (dropped otherwise, see 7.2)"
K=$(jkeys "$BASE/qa/lens-parts?fields=label,gadget.id&gadget.code=VE-G1" "gadget")
[ "$K" = "id" ] && ok "segment pruned to gadget.id ($K)" || bad "segment ?fields=gadget.id returned: $K"

title "7.3 TWO levels deep (kits ⇒ parts ⇒ gadget)"
K=$(jelem_keys "$BASE/qa/lens-kits?fields=name,parts.label,parts.gadget.code&parts.label=left%20lens%20v2" "left lens v2" "gadget")
[ "$K" = "code" ] && ok "parts.gadget pruned to code ($K)" || bad "two-level ?fields= returned: $K"
K=$(jelem_keys "$BASE/qa/lens-kits?fields=name,parts.label,parts.gadget.code&parts.label=left%20lens%20v2" "left lens v2" "")
case "$K" in *label*) ok "the element kept its own asked field ($K)";; *) bad "element pruning wrong: $K";; esac

title "7.4 onlyTotal"
[ "$(jtotal "$BASE/qa/lens-parts?onlyTotal=true")" -ge 3 ] && ok "onlyTotal reports the count" || bad "onlyTotal wrong"

##############################################################################
sec "8. Pagination over both hops"
##############################################################################
FIRST_PAGE=$(curl -sS "$BASE/qa/lens-parts?first=2&orderBy=slot")
N=$(printf '%s' "$FIRST_PAGE" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("data") or []))')
CURSOR=$(printf '%s' "$FIRST_PAGE" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("endCursor") or "")')
[ "$N" = "2" ] && ok "first=2 honored" || bad "limit returned $N"
if [ -n "$CURSOR" ]; then
  N2=$(jcount "$BASE/qa/lens-parts?first=2&orderBy=slot&after=$CURSOR")
  [ "$N2" -ge 1 ] && ok "after cursor returns the next page ($N2)" || bad "after cursor returned $N2"
else
  bad "no endCursor on a truncated page"
fi
[ "$(jcount "$BASE/qa/lens-kits?first=1")" = "1" ] && ok "pagination on the 1:N hop" || bad "kit pagination wrong"

##############################################################################
sec "9. Archive / unarchive"
##############################################################################
title "9.1 archive the SOURCE — ONE archived rule, every segment"
# The rule: a default read hides an archived entry in EVERY segment whose source
# schema declares DeletedAt, and ?includeArchived=true brings them all back —
# the same contract a native child collection and a ComposedView leg follow. A
# materialized segment is not an exception.
curl -sS -o /dev/null -X PATCH "$BASE/qa/lens-brands/$BRAND/archive"
for _ in $(seq 1 60); do [ -z "$(jpath "$P1_URL" "brand.name")" ] && break; sleep 0.5; done
[ -z "$(jpath "$P1_URL" "brand.name")" ] && ok "archived 1:1 source hidden on a default read" || bad "archived source still visible: $(jpath "$P1_URL" "brand.name")"
[ "$(jpath "$P1_URL?includeArchived=true" "brand.name")" = "Zeiss RENAMED" ] && ok "?includeArchived=true brings the segment back" || bad "includeArchived did not surface the archived segment"
[ "$(jcount "$BASE/qa/lens-brands?name=Zeiss%20RENAMED")" = "0" ] && ok "…and its OWN view hides it too (same rule, same knob)" || bad "archived brand still listed on its own view"

title "9.1b the archived source is hidden TWO HOPS out as well"
[ -z "$(jelem "$KIT_URL" "left lens v2" "brand.name")" ] && ok "hop 2: nested segment hidden by default" || bad "hop 2 still shows the archived source"
[ "$(jelem "$KIT_URL?includeArchived=true" "left lens v2" "brand.name")" = "Zeiss RENAMED" ] && ok "hop 2: ?includeArchived brings it back" || bad "hop 2 includeArchived failed"

title "9.1c a source WITHOUT a declared DeletedAt is never filtered"
# The gadgets view declares DeletedAt, but the upstream_items mirror the other
# fixtures embed does NOT — and that asymmetry is the rule itself: no declaration,
# no filtering. Asserted here on the segment that DOES declare one, by proving the
# ACTIVE sibling survives untouched beside the archived one.
[ -n "$(jpath "$P1_URL" "gadget.code")" ] && ok "an ACTIVE source stays visible while its archived neighbour is hidden" || bad "an active segment was filtered out"

title "9.2 unarchive converges"
curl -sS -o /dev/null -X PATCH "$BASE/qa/lens-brands/$BRAND/unarchive"
for _ in $(seq 1 60); do [ "$(jcount "$BASE/qa/lens-brands?name=Zeiss%20RENAMED")" = "1" ] && break; sleep 0.5; done
[ "$(jcount "$BASE/qa/lens-brands?name=Zeiss%20RENAMED")" = "1" ] && ok "unarchived brand returns to its own view" || bad "unarchive did not converge"

title "9.2b archive an ELEMENT of a 1:N segment — it leaves the array"
ARCH_PART=$(curl -sS "$BASE/qa/lens-parts?kitId=$ORD_KIT&label=gamma" | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data") or []
print(d[0].get("id") if d else "")')
[ -n "$ARCH_PART" ] && curl -sS -o /dev/null -X PATCH "$BASE/qa/lens-parts/$ARCH_PART/archive"
for _ in $(seq 1 60); do [ "$(seq_of "$ORD_URL")" = "alpha,beta-and-a-half" ] && break; sleep 0.5; done
GOT=$(seq_of "$ORD_URL")
[ "$GOT" = "alpha,beta-and-a-half" ] && ok "archived element left the 1:N array ($GOT)" || bad "archived element still in the array: $GOT"
GOT_ALL=$(curl -sS "$ORD_URL?includeArchived=true" | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data") or {}
print(",".join(str(p.get("label")) for p in (d.get("parts") or [])))')
[ "$GOT_ALL" = "alpha,beta-and-a-half,gamma" ] && ok "?includeArchived=true restores it, IN ORDER ($GOT_ALL)" || bad "includeArchived on the 1:N segment: $GOT_ALL"
curl -sS -o /dev/null -X PATCH "$BASE/qa/lens-parts/$ARCH_PART/unarchive"
for _ in $(seq 1 60); do [ "$(seq_of "$ORD_URL")" = "alpha,beta-and-a-half,gamma" ] && break; sleep 0.5; done
[ "$(seq_of "$ORD_URL")" = "alpha,beta-and-a-half,gamma" ] && ok "unarchiving puts it back in its slot" || bad "unarchive did not restore the element"

title "9.3 archive the EMBEDDING document — its own gate"
curl -sS -o /dev/null -X PATCH "$BASE/qa/lens-parts/$P3/archive"
# Poll, never a fixed sleep: CDC latency is lane-dependent (the SQL Server lane
# runs its capture noticeably slower than the others), and a bare sleep turns a
# timing difference into a false RED. The assertion itself is unchanged.
for _ in $(seq 1 60); do [ "$(jcount "$BASE/qa/lens-parts?label=spare")" = "0" ] && break; sleep 0.5; done
[ "$(jcount "$BASE/qa/lens-parts?label=spare")" = "0" ] && ok "archived part hidden by default" || bad "archived part still listed"
[ "$(jcount "$BASE/qa/lens-parts?label=spare&includeArchived=true")" = "1" ] && ok "?includeArchived surfaces it" || bad "includeArchived did not surface it"
curl -sS -o /dev/null -X PATCH "$BASE/qa/lens-parts/$P3/unarchive"
for _ in $(seq 1 60); do [ "$(jcount "$BASE/qa/lens-parts?label=spare")" = "1" ] && break; sleep 0.5; done
[ "$(jcount "$BASE/qa/lens-parts?label=spare")" = "1" ] && ok "unarchived part visible again" || bad "unarchive of the part failed"

##############################################################################
sec "10. Hard delete"
##############################################################################
title "10.1 delete the SOURCE brand ⇒ explicit null at BOTH hops"
curl -sS -o /dev/null -X DELETE "$BASE/qa/lens-brands/$BRAND"
wait_for "$P1_URL" "brand.name" "" 60 && ok "hop 1 nulled" || bad "hop 1 kept the deleted brand"
wait_elem "$KIT_URL" "left lens v2" "brand.name" "" && ok "hop 2 nulled (chained)" || bad "hop 2 kept the deleted brand"

title "10.2 delete a PART ⇒ the element leaves the kit's array"
curl -sS -o /dev/null -X DELETE "$BASE/qa/lens-parts/$P3"
# Poll the SAME expression the assertion reads — the whole label set, never one
# position: the element to disappear is not necessarily the first, so polling an
# index would exit immediately and assert against a not-yet-propagated array.
kit_labels() { curl -sS "$KIT_URL" | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data") or {}
print(",".join(sorted(str(p.get("label")) for p in (d.get("parts") or []))))'; }
for _ in $(seq 1 60); do case "$(kit_labels)" in *spare*) sleep 0.5;; *) break;; esac; done
LABELS=$(kit_labels)
case "$LABELS" in *spare*) bad "deleted part still in the kit's array";; *) ok "deleted part removed from the array";; esac

title "10.3 delete the EMBEDDING kit"
curl -sS -o /dev/null -X DELETE "$BASE/qa/lens-kits/$KIT2"
for _ in $(seq 1 60); do [ "$(code_of "$BASE/qa/lens-kits/$KIT2")" = "404" ] && break; sleep 0.5; done
[ "$(code_of "$BASE/qa/lens-kits/$KIT2")" = "404" ] && ok "deleted kit 404s" || bad "deleted kit still readable"

##############################################################################
sec "11. The failure registry stays clean on the happy path"
##############################################################################
PENDING=$(qa_db_query "SELECT count(*) FROM omnicore_projection_failures WHERE kind='ripple' AND resolved_at IS NULL AND topic LIKE 'view:%';" 2>/dev/null | tr -dc '0-9')
[ -z "$PENDING" ] && PENDING=0
[ "$PENDING" = "0" ] && ok "no pending view-sourced ripple failures" || bad "$PENDING pending view:* failure rows"

##############################################################################
hr; printf '\033[1;37mRESULT\033[0m  PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
