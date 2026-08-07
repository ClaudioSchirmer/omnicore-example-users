#!/usr/bin/env bash
# JoinView FIELDS suite — the per-leg materialization allowlist + the ARCHIVE
# SWITCH, end to end.
#
# The fixture family is qa_lens_fields_* — three ADDITIONAL projections over the
# existing lens roots (no new tables, no new write verbs; writes flow through
# /qa/lens-brands and /qa/lens-parts exactly as view_embed.sh drives them):
#
#   qa_lens_brands_view ──1:1 Fields("Name")────────────▶ qa_lens_fields_forever_view
#   qa_lens_brands_view ──1:1 Fields("Name","DeletedAt")─▶ qa_lens_fields_lifecycle_view
#   qa_lens_parts_view ───1:N Fields("Label","Slot","Brand")─▶ qa_lens_fields_kits_view
#
# Asserts, in order:
#   1  STORAGE — the stored brand segment carries ONLY the allowlist (+ identity
#      and reserved watermarks): no deleted_at / created_at / updated_at on the
#      forever view; deleted_at PRESENT on the lifecycle view; the kits view's
#      1:N elements carry label+slot+brand only (Gadget segment and the other
#      part columns CUT), asserted directly on Mongo via mongosh
#   2  ripple — a brand rename reaches the capped segment in all three views
#   3  THE ARCHIVE SWITCH — archiving the brand: the forever view keeps the
#      name on a DEFAULT read (no archived rule, by declaration; includeArchived
#      is a no-op there) while the lifecycle view hides the segment (null) and
#      ?includeArchived=true reveals it WITH its deletedAt; the kits view's
#      ADMITTED brand segment (inside the 1:N elements) follows its OWN rule —
#      hidden by default, revealed by the same flag
#   4  the cut keeps flowing — unarchive → rename → archive again: the forever
#      view shows the NEW name on a default read while the brand is archived
#   5  READ-SIDE CONTRACT — a capped field is UNKNOWN on the restricted node:
#      ?brand.deletedAt.isnull=false and ?fields=brand.deletedAt are 400 on the
#      forever view and 200 on the lifecycle view; ?fields=brand.name prunes
#   6  row-select on the capped segment still works (?brand.name=...)
#   7  EXISTENCE beats shape — a brand hard-delete nulls the segment everywhere
#   8  the failure registry stays clean (no view:* ripple rows)
#
# Prereqs: docker compose up + the OUTBOX Debezium connector registered.
# Self-managed server lifecycle. Dialect-driven via _backend.sh.
# Run from anywhere:  bash qa/fields.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-fields-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-fields-${BACKEND:-postgres}.log"
QA_YAML="$REPO_ROOT/microservice.qa.yaml"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }

drop_collections() {
  qa_view_drop qa_lens_fields_forever_view qa_lens_fields_lifecycle_view qa_lens_fields_kits_view \
               qa_lens_parts_view qa_lens_kits_view qa_lens_kits_desc_view qa_lens_brands_view
}
reset_domain() {
  qa_db_exec "DELETE FROM qa_lens_parts;"  2>/dev/null || true
  qa_db_exec "DELETE FROM qa_lens_kits;"   2>/dev/null || true
  qa_db_exec "DELETE FROM qa_lens_brands;" 2>/dev/null || true
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
patch_it()  { curl -sS -o /dev/null -w '%{http_code}' -X PATCH "$1"; }
code_of()   { curl -sS -o /dev/null -w '%{http_code}' "$@"; }
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
jtotal() { curl -sS "$1" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("pagination",{}).get("totalCount",-1))
except Exception: print(-1)'; }
wait_for() {
  local url="$1" path="$2" want="$3" tries="${4:-60}" got=""
  for _ in $(seq 1 "$tries"); do
    got=$(jpath "$url" "$path")
    [ "$got" = "$want" ] && return 0
    sleep 0.5
  done
  printf '  (last seen: %s want: %s)\n' "${got:-<empty>}" "$want"
  return 1
}
# stored_keys VIEW MATCH-JSON DOTTED — sorted keys of the object at DOTTED inside
# the STORED Mongo document matching MATCH-JSON (slot-aware via qa_view_coll).
# The storage-cut oracle: the API projects DTOs, only Mongo shows what is paid for.
stored_keys() {
  local coll; coll=$(qa_view_coll "$1")
  docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval "
    var d = db.getCollection('$coll').findOne($2);
    var seg = d; ('$3'.length ? '$3'.split('.') : []).forEach(function(k){ seg = (seg||{})[k]; });
    if (Array.isArray(seg)) seg = seg[0];
    print(seg ? Object.keys(seg).sort().join(',') : '');
  " 2>/dev/null | tr -d '[:space:]'
}

##############################################################################
sec "0. Build qa binary + connector + boot"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"

title "0.2 Ensure the outbox Debezium connector is registered"
"$REPO_ROOT/devops/debezium/register-connector.sh" "$QA_CONNECTOR_DIALECT" >/dev/null 2>&1 && ok "outbox connector registered" || bad "outbox connector registration failed"

title "0.3 Clean baseline BEFORE boot"
reset_domain
ok "clean baseline"

title "0.4 Start server (APP_PROFILE=dev, config=microservice.qa.yaml)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$QA_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 40 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready" || { bad "server not ready"; tail -n 40 "$SERVER_LOG"; exit 1; }

title "0.5 Boot accepted the Fields declarations"
grep -q "Fields entry" "$SERVER_LOG" && bad "boot rejected a Fields entry" || ok "every Fields entry resolved"
grep -q "JoinUpstream leg" "$SERVER_LOG" && bad "boot reported Fields on a JoinUpstream leg" || ok "no misplaced-Fields diagnostic"

qa_cdc_warmup_gadget

##############################################################################
sec "1. Compose + THE STORAGE CUT (asserted on Mongo, not on the DTO)"
##############################################################################
BRAND=$(post_json "$BASE/qa/lens-brands" '{"name":"Zeiss"}' | jid)
KIT=$(post_json "$BASE/qa/lens-kits" '{"name":"Alpha kit"}' | jid)
P1=$(post_json "$BASE/qa/lens-parts" "{\"kitId\":\"$KIT\",\"brandId\":\"$BRAND\",\"label\":\"alpha\",\"slot\":1}" | jid)
[ -n "$BRAND" ] && [ -n "$KIT" ] && [ -n "$P1" ] && ok "fixture rows created" || bad "fixture creation failed"

title "1.1 all three projections compose"
wait_for "$BASE/qa/lens-fields-forever/$P1"   "brand.name" "Zeiss" && ok "forever: brand.name composed"   || bad "forever compose"
wait_for "$BASE/qa/lens-fields-lifecycle/$P1" "brand.name" "Zeiss" && ok "lifecycle: brand.name composed" || bad "lifecycle compose"
wait_for "$BASE/qa/lens-fields-kits/$KIT" "parts.0.brand.name" "Zeiss" && ok "kits: element brand composed" || bad "kits compose"

title "1.2 STORAGE: the forever segment stores ONLY the allowlist (+ identity/watermarks)"
K=$(stored_keys qa_lens_fields_forever_view "{label:'alpha'}" "brand")
case ",$K," in
  *,name,*) ok "stored brand carries name ($K)" ;;
  *) bad "stored brand missing name ($K)" ;;
esac
case ",$K," in
  *,deleted_at,*|*,created_at,*|*,updated_at,*) bad "capped columns leaked into storage ($K)" ;;
  *) ok "deleted_at/created_at/updated_at NOT stored — the cut is real" ;;
esac

title "1.3 STORAGE: the lifecycle segment stores deleted_at (declared ⇒ materialized)"
KL=$(stored_keys qa_lens_fields_lifecycle_view "{label:'alpha'}" "brand")
case ",$KL," in
  *,deleted_at,*) ok "lifecycle stores deleted_at ($KL)" ;;
  *) bad "lifecycle missing deleted_at ($KL)" ;;
esac

title "1.4 STORAGE: the kits elements are capped — label+slot+brand, Gadget segment CUT"
KE=$(stored_keys qa_lens_fields_kits_view "{name:'Alpha kit'}" "parts")
case ",$KE," in
  *,label,*) ok "element stores label ($KE)" ;;
  *) bad "element missing label ($KE)" ;;
esac
case ",$KE," in
  *,gadget,*|*,brand_id,*|*,gadget_id,*|*,created_at,*) bad "cut columns/segments leaked into the element ($KE)" ;;
  *) ok "gadget segment + unlisted part columns NOT stored" ;;
esac
case ",$KE," in
  *,brand,*) ok "admitted Brand segment stored whole" ;;
  *) bad "admitted Brand segment missing ($KE)" ;;
esac

##############################################################################
sec "2. Ripple — a rename flows into every capped segment"
##############################################################################
put_json "$BASE/qa/lens-brands/$BRAND" '{"name":"Zeiss Optics"}' >/dev/null
wait_for "$BASE/qa/lens-fields-forever/$P1"   "brand.name" "Zeiss Optics" && ok "forever: rename rippled"   || bad "forever ripple"
wait_for "$BASE/qa/lens-fields-lifecycle/$P1" "brand.name" "Zeiss Optics" && ok "lifecycle: rename rippled" || bad "lifecycle ripple"
wait_for "$BASE/qa/lens-fields-kits/$KIT" "parts.0.brand.name" "Zeiss Optics" && ok "kits: rename reached the element's admitted segment" || bad "kits ripple"

##############################################################################
sec "3. THE ARCHIVE SWITCH — one entry in or out of Fields"
##############################################################################
[ "$(patch_it "$BASE/qa/lens-brands/$BRAND/archive")" = "200" ] && ok "brand archived" || bad "archive failed"

title "3.1 forever (DeletedAt OUT): the name stays on a DEFAULT read"
wait_for "$BASE/qa/lens-fields-lifecycle/$P1" "brand" "" 60 >/dev/null   # settle on the lifecycle side first
[ "$(jpath "$BASE/qa/lens-fields-forever/$P1" "brand.name")" = "Zeiss Optics" ] \
  && ok "forever keeps the archived brand's name — no archived rule, by declaration" \
  || bad "forever lost the name on archive"

title "3.2 lifecycle (DeletedAt IN): hidden by default, revealed by ?includeArchived"
[ "$(jpath "$BASE/qa/lens-fields-lifecycle/$P1" "brand")" = "" ] && ok "lifecycle hides the segment (null)" || bad "lifecycle did not hide"
[ "$(jpath "$BASE/qa/lens-fields-lifecycle/$P1?includeArchived=true" "brand.name")" = "Zeiss Optics" ] && ok "includeArchived reveals the segment" || bad "includeArchived did not reveal"
DA=$(jpath "$BASE/qa/lens-fields-lifecycle/$P1?includeArchived=true" "brand.deletedAt")
[ -n "$DA" ] && ok "revealed segment carries deletedAt ($DA)" || bad "revealed segment missing deletedAt"

title "3.3 forever: includeArchived is a NO-OP (nothing was hidden)"
[ "$(jpath "$BASE/qa/lens-fields-forever/$P1?includeArchived=true" "brand.name")" = "Zeiss Optics" ] && ok "same answer with the flag" || bad "flag changed the forever view"

title "3.4 kits: the ADMITTED segment follows ITS OWN rule inside the elements"
[ "$(jpath "$BASE/qa/lens-fields-kits/$KIT" "parts.0.brand")" = "" ] && ok "element's brand hidden by default (admitted whole ⇒ own rules)" || bad "element brand not hidden"
[ "$(jpath "$BASE/qa/lens-fields-kits/$KIT?includeArchived=true" "parts.0.brand.name")" = "Zeiss Optics" ] && ok "flag reveals it inside the element too" || bad "element brand not revealed"

##############################################################################
sec "4. The cut keeps flowing — rename across an archive cycle"
##############################################################################
[ "$(patch_it "$BASE/qa/lens-brands/$BRAND/unarchive")" = "200" ] && ok "brand unarchived" || bad "unarchive failed"
wait_for "$BASE/qa/lens-fields-lifecycle/$P1" "brand.name" "Zeiss Optics" && ok "lifecycle back on default read" || bad "lifecycle did not return"
put_json "$BASE/qa/lens-brands/$BRAND" '{"name":"Zeiss Vision"}' >/dev/null
wait_for "$BASE/qa/lens-fields-forever/$P1" "brand.name" "Zeiss Vision" && ok "rename after the cycle rippled" || bad "post-cycle ripple"
[ "$(patch_it "$BASE/qa/lens-brands/$BRAND/archive")" = "200" ] || bad "re-archive failed"
wait_for "$BASE/qa/lens-fields-lifecycle/$P1" "brand" "" && ok "lifecycle hides again" || bad "lifecycle did not hide again"
[ "$(jpath "$BASE/qa/lens-fields-forever/$P1" "brand.name")" = "Zeiss Vision" ] \
  && ok "forever shows the NEW name while the brand is archived — the feature, end to end" \
  || bad "forever lost the post-cycle name"

##############################################################################
sec "5. Read-side contract — a capped field is UNKNOWN, not silently empty"
##############################################################################
title "5.1 filter on the capped column — the DTO mirrors the cut: 400 on forever, 200 on lifecycle"
[ "$(code_of "$BASE/qa/lens-fields-forever/?brand.deletedAt=2020-01-01")"   = "400" ] && ok "forever: ?brand.deletedAt → 400 (token not declared — the DTO mirrors the cut)" || bad "forever accepted a capped-field filter"
[ "$(code_of "$BASE/qa/lens-fields-lifecycle/?brand.deletedAt=2020-01-01")" = "200" ] && ok "lifecycle: same token is a declared, real query" || bad "lifecycle rejected a declared field"

title "5.2 ?fields= into the capped column — same layering: 400 on forever, 200 on lifecycle"
[ "$(code_of "$BASE/qa/lens-fields-forever/?fields=brand.deletedAt")"   = "400" ] && ok "forever: ?fields=brand.deletedAt → 400 (projection allowlist mirrors the cut)" || bad "forever accepted a capped ?fields token"
[ "$(code_of "$BASE/qa/lens-fields-lifecycle/?fields=brand.deletedAt&includeArchived=true")" = "200" ] && ok "lifecycle: the token projects" || bad "lifecycle rejected the token"

title "5.3 ?fields=brand.name prunes to the declared entry"
[ "$(jkeys "$BASE/qa/lens-fields-forever/?fields=brand.name" "brand")" = "name" ] && ok "segment pruned to name" || bad "segment pruning wrong"

##############################################################################
sec "6. Row-select on the capped segment"
##############################################################################
[ "$(jtotal "$BASE/qa/lens-fields-forever/?brand.name=Zeiss%20Vision&onlyTotal=true")" = "1" ] && ok "?brand.name selects the row (materialized semantics)" || bad "segment row-select failed"
[ "$(jtotal "$BASE/qa/lens-fields-forever/?brand.name=No%20Such&onlyTotal=true")" = "0" ] && ok "match-nothing → 0 rows" || bad "match-nothing wrong"

##############################################################################
sec "7. Existence beats shape — hard delete nulls the segment everywhere"
##############################################################################
# The brand is archived (sec 4) and a hard delete is scope-gated to active
# rows, so unarchive first — the delete itself is what this section tests.
patch_it "$BASE/qa/lens-brands/$BRAND/unarchive" >/dev/null
wait_for "$BASE/qa/lens-fields-lifecycle/$P1" "brand.name" "Zeiss Vision" >/dev/null
DC=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASE/qa/lens-brands/$BRAND")
case "$DC" in 200|204) ok "brand hard-deleted ($DC)" ;; *) bad "hard delete failed ($DC)" ;; esac
wait_for "$BASE/qa/lens-fields-forever/$P1" "brand" "" && ok "forever: segment null after hard delete (Fields never fakes existence)" || bad "forever kept a deleted brand"
wait_for "$BASE/qa/lens-fields-lifecycle/$P1?includeArchived=true" "brand" "" && ok "lifecycle: null even with the flag" || bad "lifecycle kept a deleted brand"

##############################################################################
sec "8. Failure registry stays clean"
##############################################################################
ROWS=$(qa_db_query "SELECT COUNT(*) FROM omnicore_projection_failures WHERE topic LIKE 'view:%' AND aggregate_type LIKE 'qa_lens_fields%'" 2>/dev/null | tr -d '[:space:]')
[ "${ROWS:-0}" = "0" ] && ok "no view:* ripple failures for the fields family" || bad "ripple failures recorded: $ROWS"

hr
printf '\033[1;37mRESULT\033[0m  PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
