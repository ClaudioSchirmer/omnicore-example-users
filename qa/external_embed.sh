#!/usr/bin/env bash
# External Embed + EmbedMany suite — the full matrix {normal view, shared-base
# view} × {Embed 1:1, EmbedMany 1:N}, over CDC.
#
# The qa-only Item aggregate feeds a filtered `upstream_items` projection (its
# OWN qa_items.events topic → the outbox EventRouter → an upstreamSubscription).
# TWO views embed that projection:
#   - qa_accounts_view (SharedBaseView, AccountHolder role over the qa_accounts
#     base): Embed "featuredItem" (1:1, base.featured_item_id → item _id) +
#     EmbedMany "items" (1:N, upstream_items.account_id → account _id).
#   - qa_catalog_view (normal query.View over qa_catalogs): the SAME two embeds,
#     the 1:N joined on upstream_items.catalog_id → catalog _id.
#
# Asserts, for BOTH view kinds:
#   (1) compose — the 1:1 featured sub-document + the 1:N items array resolve;
#       a null-FK item never leaks into any parent's list;
#   (2) ripple, label — patching an item's label recomposes the parent's
#       FeaturedItem (1:1) and Items (1:N) segments with no write to the parent;
#   (3) ripple, delete — hard-deleting an item drops it from the parent list
#       (onUpstreamDelete cascade + recompose);
#   (4) ripple, move — reassigning an item's FK recomposes BOTH the old and the
#       new parent (drop here, appear there) from one event.
#
# Uses the qa binary + microservice.qa.yaml. Self-managed server. Dialect-driven.
# Prereqs: docker compose up + the OUTBOX Debezium connector registered.
#
# Run from anywhere:  bash qa/external_embed.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-external-embed-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-external-embed-${BACKEND:-postgres}.log"
QA_YAML="$REPO_ROOT/microservice.qa.yaml"
GET_TMP="/tmp/qa-ee-get.json.${BACKEND:-default}"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
drop_collections() {
  qa_view_drop qa_accounts_view qa_catalog_view upstream_items
}
reset_domain() {
  qa_db_exec "DELETE FROM qa_items;" 2>/dev/null || true
  qa_db_exec "DELETE FROM qa_account_holders;" 2>/dev/null || true
  qa_db_exec "DELETE FROM qa_accounts;" 2>/dev/null || true
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
# jval URL PATH -> value at data.<dotted path> ("" if absent)
jval() {
  curl -sS -o "$GET_TMP" "$1"
  python3 -c '
import sys, json
try: d = json.load(open(sys.argv[1]))
except Exception: print(""); sys.exit()
cur = d.get("data")
for k in sys.argv[2].split("."):
    cur = cur.get(k) if isinstance(cur, dict) else None
print("" if cur is None else cur)' "$GET_TMP" "$2"
}
# jitems URL SEGMENT -> sorted, comma-joined labels of the data.<segment> array
jitems() {
  curl -sS -o "$GET_TMP" "$1"
  python3 -c '
import sys, json
try: d = json.load(open(sys.argv[1]))
except Exception: print(""); sys.exit()
arr = (d.get("data") or {}).get(sys.argv[2]) or []
print(",".join(sorted(x.get("label","") for x in arr if isinstance(x, dict))))' "$GET_TMP" "$2"
}
# ── paged-list helpers (GET envelope: data:[...] + pagination.total) ─────────
# lget URL [k=v ...] — GET the list with url-encoded query args into GET_TMP
lget() { local url="$1"; shift; local a=(); local kv; for kv in "$@"; do a+=(--data-urlencode "$kv"); done; curl -sS -G -o "$GET_TMP" "$url" ${a[@]+"${a[@]}"}; }
ltotal() { python3 -c 'import sys,json;print((json.load(open(sys.argv[1])).get("pagination") or {}).get("total",""))' "$GET_TMP"; }
lcount() { python3 -c 'import sys,json;d=json.load(open(sys.argv[1])).get("data");print(len(d) if isinstance(d,list) else 0)' "$GET_TMP"; }
# lfield IDX DOTTED — data[IDX].<dotted> (arrays take the first element)
lfield() { python3 -c '
import sys, json
d = json.load(open(sys.argv[1])).get("data") or []
i = int(sys.argv[2]); cur = d[i] if i < len(d) else None
for k in sys.argv[3].split("."):
    if isinstance(cur, list): cur = cur[0] if cur else None
    cur = cur.get(k) if isinstance(cur, dict) else None
    if cur is None: break
print("" if cur is None else cur)' "$GET_TMP" "$1" "$2"; }
# lhaskey IDX KEY — is KEY present on data[IDX]? (y/n) — for ?fields= sparse checks
lhaskey() { python3 -c '
import sys, json
d = json.load(open(sys.argv[1])).get("data") or []
i = int(sys.argv[2]); print("y" if i < len(d) and isinstance(d[i], dict) and sys.argv[3] in d[i] else "n")' "$GET_TMP" "$1" "$2"; }

# wait_val URL PATH EXPECTED — poll until data.<path> == EXPECTED (or deadline)
wait_val() {
  local deadline=$(( $(date +%s) + QA_CDC_DEADLINE )) got=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    got=$(jval "$1" "$2"); [ "$got" = "$3" ] && return 0; sleep 1
  done
  echo "    (last seen: '$got', wanted: '$3')" >&2; return 1
}
# wait_items URL SEGMENT EXPECTED_CSV — poll until sorted labels match
wait_items() {
  local deadline=$(( $(date +%s) + QA_CDC_DEADLINE )) got=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    got=$(jitems "$1" "$2"); [ "$got" = "$3" ] && return 0; sleep 1
  done
  echo "    (last seen: '$got', wanted: '$3')" >&2; return 1
}

##############################################################################
sec "0. Build qa binary + ensure outbox connector + boot with qa.yaml"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"

title "0.2 Ensure the outbox Debezium connector is registered (routes qa_items.events)"
"$REPO_ROOT/devops/debezium/register-connector.sh" "$QA_CONNECTOR_DIALECT" >/dev/null 2>&1 && ok "outbox connector registered" || bad "outbox connector registration failed"

title "0.3 Start server (APP_PROFILE=dev, config=microservice.qa.yaml)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$QA_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready" || { bad "server not ready"; tail -n 40 "$SERVER_LOG"; exit 1; }

# Prove the CDC pipeline is hot before per-step deadlines start counting.
qa_cdc_warmup_gadget

title "0.4 Clean baseline (qa_items/accounts/catalogs + the view + projection collections)"
reset_domain
sleep 1
ok "clean baseline"

##############################################################################
sec "1. Create the embed sources (items) + both parents"
##############################################################################
title "1.1 Two featured items (no FK — referenced 1:1 only)"
FA_ID=$(new_item '{"label":"FA-featured"}')
FC_ID=$(new_item '{"label":"FC-featured"}')
{ [ -n "$FA_ID" ] && [ -n "$FC_ID" ]; } && ok "featured items created (account=$FA_ID catalog=$FC_ID)" || { bad "featured item create failed"; }

title "1.2 Shared-base account (featuredItemId=FA) + a second account (move target) + normal catalog (featuredItemId=FC)"
ACC_ID=$(post_json "$BASE/qa/accounts" "{\"accountRef\":\"acct-001\",\"displayName\":\"Primary Account\",\"holderName\":\"Ada Lovelace\",\"featuredItemId\":\"$FA_ID\"}" | jid)
ACC2_ID=$(post_json "$BASE/qa/accounts" '{"accountRef":"acct-002","displayName":"Second Account","holderName":"Grace Hopper"}' | jid)
CAT_ID=$(post_json "$BASE/qa/catalogs" "{\"name\":\"Summer Collection\",\"featuredItemId\":\"$FC_ID\"}" | jid)
{ [ -n "$ACC_ID" ] && [ -n "$ACC2_ID" ] && [ -n "$CAT_ID" ]; } && ok "parents created (acc=$ACC_ID acc2=$ACC2_ID cat=$CAT_ID)" || { bad "parent create failed"; }

title "1.3 List items — two for the account (account_id), two for the catalog (catalog_id)"
A1_ID=$(new_item "{\"label\":\"A1\",\"accountId\":\"$ACC_ID\"}")
A2_ID=$(new_item "{\"label\":\"A2\",\"accountId\":\"$ACC_ID\"}")
C1_ID=$(new_item "{\"label\":\"C1\",\"catalogId\":\"$CAT_ID\"}")
C2_ID=$(new_item "{\"label\":\"C2\",\"catalogId\":\"$CAT_ID\"}")
{ [ -n "$A1_ID" ] && [ -n "$A2_ID" ] && [ -n "$C1_ID" ] && [ -n "$C2_ID" ]; } && ok "list items created" || bad "list item create failed"

ACC_URL="$BASE/qa/accounts/$ACC_ID"
ACC2_URL="$BASE/qa/accounts/$ACC2_ID"
CAT_URL="$BASE/qa/catalogs/$CAT_ID"

##############################################################################
sec "2. Shared-base view (qa_accounts_view) — compose"
##############################################################################
title "2.1 The 1:1 Embed (featuredItem) resolves the featured item"
wait_val "$ACC_URL" "featuredItem.label" "FA-featured" && ok "account featuredItem = FA-featured (Embed 1:1 on a shared-base root)" || bad "account featuredItem never resolved"

title "2.2 The 1:N EmbedMany (items) carries exactly the account's items"
wait_items "$ACC_URL" "items" "A1,A2" && ok "account items = [A1,A2] (EmbedMany 1:N on a shared-base root); null-FK + catalog items excluded" || bad "account items wrong"

title "2.3 The base fields + role sub-document compose alongside the embeds"
{ [ "$(jval "$ACC_URL" displayName)" = "Primary Account" ] && [ "$(jval "$ACC_URL" accountHolder.holderName)" = "Ada Lovelace" ]; } \
  && ok "base displayName + AccountHolder role segment present next to the embeds" || bad "base/role fields missing"

##############################################################################
sec "3. Normal view (qa_catalog_view) — compose"
##############################################################################
title "3.1 The 1:1 Embed (featuredItem) resolves on a REGULAR view"
wait_val "$CAT_URL" "featuredItem.label" "FC-featured" && ok "catalog featuredItem = FC-featured (Embed 1:1 on a normal view)" || bad "catalog featuredItem never resolved"

title "3.2 The 1:N EmbedMany (items) carries exactly the catalog's items"
wait_items "$CAT_URL" "items" "C1,C2" && ok "catalog items = [C1,C2] (EmbedMany 1:N on a normal view)" || bad "catalog items wrong"

##############################################################################
sec "4. Read-side vocabulary over embedded segments (list/filter/sort/fields/onlyTotal/export)"
##############################################################################
# Run BEFORE the ripple mutations, so the data is the clean compose state:
#   accounts: acct-001 (featured FA-featured, items A1,A2) + acct-002 (no featured, no items)
#   catalog : Summer Collection (featured FC-featured, items C1,C2)
ACCLIST="$BASE/qa/accounts"
CATLIST="$BASE/qa/catalogs"

title "4.1 Paged list — total counts the ROOT docs (embeds don't inflate it)"
lget "$ACCLIST"; [ "$(ltotal)" = "2" ] && ok "accounts list total=2 (both accounts)" || bad "accounts list total=$(ltotal), want 2"
lget "$CATLIST"; [ "$(ltotal)" = "1" ] && ok "catalogs list total=1" || bad "catalogs list total=$(ltotal), want 1"

title "4.2 Root filter selects rows (both view kinds)"
lget "$ACCLIST" "accountRef=acct-001"; { [ "$(lcount)" = "1" ] && [ "$(lfield 0 accountRef)" = "acct-001" ]; } && ok "?accountRef=acct-001 → 1 row" || bad "root filter (account) wrong"
lget "$CATLIST" "name=Summer Collection"; { [ "$(lcount)" = "1" ] && [ "$(lfield 0 name)" = "Summer Collection" ]; } && ok "?name=Summer Collection → 1 row" || bad "root filter (catalog) wrong"

title "4.3 Role-segment filter (accountHolder.holderName) — shared-base"
lget "$ACCLIST" "accountHolder.holderName=Ada Lovelace"; { [ "$(lcount)" = "1" ] && [ "$(lfield 0 accountRef)" = "acct-001" ]; } && ok "?accountHolder.holderName= resolves into the role segment" || bad "role-segment filter wrong"

title "4.4 Embed 1:1 segment filter (featuredItem.label) — both view kinds"
lget "$ACCLIST" "featuredItem.label=FA-featured"; { [ "$(lcount)" = "1" ] && [ "$(lfield 0 accountRef)" = "acct-001" ]; } && ok "account ?featuredItem.label= selects the account featuring it (1:1 embed, shared-base)" || bad "1:1 segment filter (account) wrong"
lget "$CATLIST" "featuredItem.label=FC-featured"; [ "$(lcount)" = "1" ] && ok "catalog ?featuredItem.label= selects the catalog featuring it (1:1 embed, normal view)" || bad "1:1 segment filter (catalog) wrong"

title "4.5 Embed 1:N segment filter (items.label) — array-element match selects the row"
lget "$ACCLIST" "items.label=A1"; { [ "$(lcount)" = "1" ] && [ "$(lfield 0 accountRef)" = "acct-001" ]; } && ok "account ?items.label=A1 → the account owning it (1:N embed)" || bad "1:N segment filter (account) wrong"
lget "$CATLIST" "items.label=C1"; [ "$(lcount)" = "1" ] && ok "catalog ?items.label=C1 → the catalog owning it (1:N embed, normal view)" || bad "1:N segment filter (catalog) wrong"
lget "$ACCLIST" "items.label=does-not-exist"; [ "$(lcount)" = "0" ] && ok "?items.label=does-not-exist → 0 rows (no false positives)" || bad "1:N segment filter should exclude non-matches"

title "4.6 Sort on a root field (asc + desc)"
lget "$ACCLIST" "sort=displayName"; [ "$(lfield 0 displayName)" = "Primary Account" ] && ok "?sort=displayName → Primary first" || bad "sort asc wrong (got '$(lfield 0 displayName)')"
lget "$ACCLIST" "sort=-displayName"; [ "$(lfield 0 displayName)" = "Second Account" ] && ok "?sort=-displayName → Second first" || bad "sort desc wrong (got '$(lfield 0 displayName)')"

title "4.7 Sparse projection (?fields=) — prunes the root AND into an embed segment"
lget "$ACCLIST" "accountRef=acct-001" "fields=displayName"; { [ "$(lhaskey 0 displayName)" = y ] && [ "$(lhaskey 0 featuredItem)" = n ] && [ "$(lhaskey 0 items)" = n ]; } && ok "?fields=displayName drops the featuredItem + items segments" || bad "sparse root projection wrong"
lget "$ACCLIST" "accountRef=acct-001" "fields=displayName,items.label"; { [ "$(lhaskey 0 items)" = y ] && [ "$(lhaskey 0 featuredItem)" = n ]; } && ok "?fields=displayName,items.label keeps only the items segment" || bad "sparse segment projection wrong"

title "4.8 onlyTotal — count without materializing rows"
lget "$ACCLIST" "onlyTotal=true"; { [ "$(ltotal)" = "2" ] && [ "$(lcount)" = "0" ]; } && ok "?onlyTotal=true → total=2, empty data array" || bad "onlyTotal wrong (total=$(ltotal) count=$(lcount))"

title "4.9 Tabular export (CSV) walks the embed segment branches"
curl -sS -o "$GET_TMP" "$ACCLIST.csv"; { grep -q "Primary Account" "$GET_TMP" && grep -q "A1" "$GET_TMP"; } && ok "accounts.csv carries the root + an embedded item label" || bad "accounts CSV missing root/embed data"
curl -sS -o "$GET_TMP" "$CATLIST.csv"; { grep -q "Summer Collection" "$GET_TMP" && grep -q "C1" "$GET_TMP"; } && ok "catalogs.csv carries the root + an embedded item label" || bad "catalogs CSV missing root/embed data"

##############################################################################
sec "5. Recompose ripple — item label change (1:1 AND 1:N, both views)"
##############################################################################
title "4.1 Rename the account's featured item → the 1:1 segment ripples"
curl -sS -o /dev/null -X PATCH "$BASE/qa/items/$FA_ID" -H "Content-Type: application/json" --data '{"label":"FA-renamed"}'
wait_val "$ACC_URL" "featuredItem.label" "FA-renamed" && ok "account featuredItem rippled to FA-renamed" || bad "account 1:1 ripple failed"

title "4.2 Rename an account list item → the 1:N segment ripples"
curl -sS -o /dev/null -X PATCH "$BASE/qa/items/$A1_ID" -H "Content-Type: application/json" --data '{"label":"A1-renamed"}'
wait_items "$ACC_URL" "items" "A1-renamed,A2" && ok "account items rippled to [A1-renamed,A2]" || bad "account 1:N ripple failed"

title "4.3 Rename the catalog's featured item → the 1:1 segment ripples (normal view)"
curl -sS -o /dev/null -X PATCH "$BASE/qa/items/$FC_ID" -H "Content-Type: application/json" --data '{"label":"FC-renamed"}'
wait_val "$CAT_URL" "featuredItem.label" "FC-renamed" && ok "catalog featuredItem rippled to FC-renamed" || bad "catalog 1:1 ripple failed"

title "4.4 Rename a catalog list item → the 1:N segment ripples (normal view)"
curl -sS -o /dev/null -X PATCH "$BASE/qa/items/$C1_ID" -H "Content-Type: application/json" --data '{"label":"C1-renamed"}'
wait_items "$CAT_URL" "items" "C1-renamed,C2" && ok "catalog items rippled to [C1-renamed,C2]" || bad "catalog 1:N ripple failed"

##############################################################################
sec "6. Recompose ripple — item delete (drops from the 1:N list)"
##############################################################################
title "5.1 Hard-delete account item A2 → it drops from the account's Items array"
curl -sS -o /dev/null -X DELETE "$BASE/qa/items/$A2_ID"
wait_items "$ACC_URL" "items" "A1-renamed" && ok "A2 dropped from account items on delete (cascade + recompose)" || bad "delete ripple failed (A2 survived)"

##############################################################################
sec "7. Recompose ripple — item move (BOTH old and new parent recompose)"
##############################################################################
title "6.1 Reassign A1 from account acct-001 → account acct-002 (one event, two parents)"
curl -sS -o /dev/null -X PATCH "$BASE/qa/items/$A1_ID" -H "Content-Type: application/json" --data "{\"accountId\":\"$ACC2_ID\"}"
title "6.2 A1 leaves the OLD account's list"
wait_items "$ACC_URL" "items" "" && ok "old account items now empty (A1 removed on move)" || bad "old parent not recomposed on move"
title "6.3 A1 appears in the NEW account's list"
wait_items "$ACC2_URL" "items" "A1-renamed" && ok "new account items = [A1-renamed] (A1 added on move)" || bad "new parent not recomposed on move"

##############################################################################
sec "8. Blue-green rebuild — batched embed compose (multi-parent backfill)"
##############################################################################
# Sections 2-7 exercise the PER-EVENT compose path (one parent recomposed per CDC
# event → the per-row applyEmbeds). A full rebuild instead composes MANY parents
# per batch and resolves each parent's external embed through the SET-BASED
# applyEmbedsBatch (one $in per embed source, grouped by join key). This step
# drops BOTH embed views' Mongo collections across every physical slot (keeping
# the embed SOURCE upstream_items) and reboots, so the boot rebuild backfills them
# via ComposeBatch → applyEmbedsBatch — then proves the rebuilt docs reproduce the
# live projection EXACTLY, on BOTH view kinds and across a parent WITH embeds
# (acct-001) and one WITHOUT/moved-in (acct-002); a mis-grouped $in would surface
# as a wrong or leaked segment on the wrong parent.

title "8.1 Capture the live projection (post-ripple) before the rebuild"
acc_feat=$(jval "$ACC_URL" "featuredItem.label"); acc_items=$(jitems "$ACC_URL" "items")
acc2_feat=$(jval "$ACC2_URL" "featuredItem.label"); acc2_items=$(jitems "$ACC2_URL" "items")
cat_feat=$(jval "$CAT_URL" "featuredItem.label"); cat_items=$(jitems "$CAT_URL" "items")
ok "captured account=[$acc_feat|$acc_items] account2=[$acc2_feat|$acc2_items] catalog=[$cat_feat|$cat_items]"

title "8.2 Stop the server + WIPE both embed views (all slots); keep upstream_items"
if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
kill_port "${HTTP_PORT:-8080}"
qa_view_drop qa_accounts_view qa_catalog_view
ok "embed views wiped (registry rows kept → DriftMongoWiped next boot; embed source intact)"

title "8.3 Reboot → the boot rebuild backfills both views (ComposeBatch → applyEmbedsBatch)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$QA_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
d=$(( $(date +%s) + 90 )); rok=fail
while [ "$(date +%s)" -lt "$d" ]; do [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/readyz")" = 200 ] && { rok=ok; break; }; sleep 0.5; done
[ "$rok" = ok ] && ok "server ready (boot rebuild finished)" || { bad "server never became ready after rebuild"; tail -n 40 "$SERVER_LOG"; }

title "8.4 A blue-green rebuild actually ran (only the wiped embed views drift)"
grep -q 'view.rebuild.end' "$SERVER_LOG" && ok "boot rebuild ran (view.rebuild.end in the server log)" || bad "no view.rebuild in the server log — the batched embed path was not exercised"

title "8.5 The batch-composed docs reproduce the live projection EXACTLY (embeds grouped per parent)"
{ wait_val "$ACC_URL" "featuredItem.label" "$acc_feat" && wait_items "$ACC_URL" "items" "$acc_items"; } \
  && ok "shared-base account embeds survived the rebuild (featuredItem=$acc_feat items=[$acc_items])" \
  || bad "account embeds diverged after the batched rebuild"
{ wait_val "$ACC2_URL" "featuredItem.label" "$acc2_feat" && wait_items "$ACC2_URL" "items" "$acc2_items"; } \
  && ok "second account regrouped correctly — no cross-parent leak (featuredItem=$acc2_feat items=[$acc2_items])" \
  || bad "second account embeds diverged after the batched rebuild"
{ wait_val "$CAT_URL" "featuredItem.label" "$cat_feat" && wait_items "$CAT_URL" "items" "$cat_items"; } \
  && ok "normal-view catalog embeds survived the rebuild (featuredItem=$cat_feat items=[$cat_items])" \
  || bad "catalog embeds diverged after the batched rebuild"

##############################################################################
sec "9. Surgical commute — a rapid same-parent burst converges to the exact set"
##############################################################################
# Concurrent ripples for DIFFERENT items of one parent are per-element edits
# that commute — no snapshot write may erase a sibling's element. A back-to-back
# burst is the behavioral probe: any lost-update leaves the final array short.
title "9.1 Four items created back-to-back for acct-001"
B1_ID=$(new_item "{\"label\":\"B1\",\"accountId\":\"$ACC_ID\"}")
B2_ID=$(new_item "{\"label\":\"B2\",\"accountId\":\"$ACC_ID\"}")
B3_ID=$(new_item "{\"label\":\"B3\",\"accountId\":\"$ACC_ID\"}")
B4_ID=$(new_item "{\"label\":\"B4\",\"accountId\":\"$ACC_ID\"}")
wait_items "$ACC_URL" "items" "B1,B2,B3,B4" && ok "burst converged to the exact set [B1,B2,B3,B4] (commuting per-element edits)" || bad "burst lost an element (snapshot lost-update)"

title "9.2 Interleaved delete + move settle to the exact final sets on BOTH parents"
curl -sS -o /dev/null -X DELETE "$BASE/qa/items/$B2_ID"
curl -sS -o /dev/null -X PATCH "$BASE/qa/items/$B3_ID" -H "Content-Type: application/json" --data "{\"accountId\":\"$ACC2_ID\"}"
wait_items "$ACC_URL" "items" "B1,B4" && ok "old parent settled to [B1,B4] (delete + move-out interleaved)" || bad "old parent items wrong after interleaved delete+move"
wait_items "$ACC2_URL" "items" "A1-renamed,B3" && ok "new parent settled to [A1-renamed,B3] (move-in landed)" || bad "new parent items wrong after move-in"

##############################################################################
sec "10. 1:1 source deletion — featuredItem clears to null (both view kinds)"
##############################################################################
# The unresolved 1:1 contract: the source doc vanishing must write an EXPLICIT
# null over the stale sub-document ($set-merged docs would otherwise keep it).
title "10.1 Delete the account's featured item → featuredItem null on the shared-base view"
curl -sS -o /dev/null -X DELETE "$BASE/qa/items/$FA_ID"
wait_val "$ACC_URL" "featuredItem.label" "" && ok "account featuredItem cleared to null after source delete" || bad "account featuredItem still holds the deleted item"

title "10.2 Delete the catalog's featured item → featuredItem null on the normal view"
curl -sS -o /dev/null -X DELETE "$BASE/qa/items/$FC_ID"
wait_val "$CAT_URL" "featuredItem.label" "" && ok "catalog featuredItem cleared to null after source delete" || bad "catalog featuredItem still holds the deleted item"

##############################################################################
sec "11. Online rebuild — ripples fired mid-window survive the flip (dual-apply)"
##############################################################################
# Every writer of a view doc must reach the SHADOW slot during a rebuild
# window. The widened fence lease keeps qa_accounts_view's window open for
# seconds while items are written: their ripples land while the shadow is
# live, and after the flip the served collection IS that shadow — a ripple
# that skipped it surfaces as missing items here.
title "11.1 Wipe both embed views + reboot with a widened rebuild window (pointerLeaseSeconds: 6)"
if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
kill_port "${HTTP_PORT:-8080}"
qa_view_drop qa_accounts_view qa_catalog_view
LEASE_YAML="/tmp/qa-embed-lease-${BACKEND}.yaml"
sed 's/pointerLeaseSeconds: 2/pointerLeaseSeconds: 6/' "$QA_YAML" > "$LEASE_YAML"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$LEASE_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
ok "server rebooting with the widened window (DriftMongoWiped → online rebuild)"

title "11.2 Fire item writes while qa_accounts_view rebuilds"
d=$(( $(date +%s) + 120 )); marker=fail
while [ "$(date +%s)" -lt "$d" ]; do
  grep -q 'view.rebuild.start.*qa_accounts_view' "$SERVER_LOG" 2>/dev/null && { marker=ok; break; }
  sleep 0.5
done
[ "$marker" = ok ] && ok "qa_accounts_view rebuild window open" || bad "qa_accounts_view rebuild never started"
for i in 1 2 3 4 5; do
  new_item "{\"label\":\"W$i\",\"accountId\":\"$ACC_ID\"}" >/dev/null
  sleep 2
done
ok "five items written across the rebuild window"

title "11.3 Server ready (rebuild finished, flip done)"
d=$(( $(date +%s) + 240 )); rok=fail
while [ "$(date +%s)" -lt "$d" ]; do [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/readyz")" = 200 ] && { rok=ok; break; }; sleep 1; done
[ "$rok" = ok ] && ok "server ready after the widened-window rebuild" || bad "server never became ready after the widened-window rebuild"

title "11.4 Every mid-window item is present in the FLIPPED view (zero loss)"
wait_items "$ACC_URL" "items" "B1,B4,W1,W2,W3,W4,W5" && ok "all mid-rebuild ripples survived the flip (dual-apply to the shadow)" || bad "the flipped view lost mid-rebuild ripples"

##############################################################################
sec "12. ENTITY-side 1:1 FK change — the parent repoints featuredItemId (upsert)"
##############################################################################
# Coverage audit 2026-07-21: every 1:1 mutation so far came from the ITEM side
# (rename/delete). The parent repointing its own FK was never exercised — and
# was in fact INEXPRESSIBLE (re-POST of the same holder is a 409, matching the
# users semantics), so the fixture gained PATCH /qa/accounts/:id. This is
# exactly the dangling-FK case the post-write repair handshake closes:
# ownership forbids the consult write from touching the segment, so the repair
# (or the item's own ripple) must converge it. An explicit null clear stays
# inexpressible under partial semantics — the null outcome is §10's
# source-delete path.
title "12.1 null → FN (a fresh item): segment materializes from the new reference"
FN_ID=$(new_item '{"label":"FN-repoint"}')
st=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH "$BASE/qa/accounts/$ACC_ID" -H "Content-Type: application/json" --data "{\"featuredItemId\":\"$FN_ID\"}")
[ "$st" = "200" ] && ok "PATCH accepted (200)" || bad "PATCH status $st"
wait_val "$ACC_URL" "featuredItem.label" "FN-repoint" && ok "featuredItem repointed null → FN-repoint (entity-side FK change)" || bad "featuredItem never converged to FN-repoint"

title "12.2 FN → FN2 (both items already exist): pure repoint between live references"
FN2_ID=$(new_item '{"label":"FN2-repoint"}')
st=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH "$BASE/qa/accounts/$ACC_ID" -H "Content-Type: application/json" --data "{\"featuredItemId\":\"$FN2_ID\"}")
[ "$st" = "200" ] && ok "PATCH accepted (200)" || bad "PATCH status $st"
wait_val "$ACC_URL" "featuredItem.label" "FN2-repoint" && ok "featuredItem repointed FN → FN2 (segment follows the FK, no item event involved)" || bad "featuredItem never converged to FN2-repoint"

##############################################################################
sec "13. workers > 1 — commuting edits under real worker concurrency"
##############################################################################
# Coverage audit 2026-07-21: every lane runs the items subscription with
# workers: 1, so in-process concurrency between ripples of DIFFERENT items was
# never exercised end to end. The surgical per-element edits must commute
# across three workers (same-item ordering stays guaranteed by the
# hash-bucketed dispatch); any snapshot-style lost-update surfaces as a short
# array.
title "13.1 Reboot with workers: 3 on the upstream subscriptions"
if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
kill_port "${HTTP_PORT:-8080}"
WORKERS_YAML="/tmp/qa-embed-workers-${BACKEND}.yaml"
sed 's/workers: 1/workers: 3/' "$QA_YAML" > "$WORKERS_YAML"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$WORKERS_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
d=$(( $(date +%s) + 90 )); rok=fail
while [ "$(date +%s)" -lt "$d" ]; do [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/readyz")" = 200 ] && { rok=ok; break; }; sleep 1; done
[ "$rok" = ok ] && ok "server ready with 3 subscription workers" || bad "server never ready on the workers-3 yaml"

title "13.2 Six-item burst on acct-002 across 3 workers → exact set"
K1_ID=$(new_item "{\"label\":\"K1\",\"accountId\":\"$ACC2_ID\"}")
K2_ID=$(new_item "{\"label\":\"K2\",\"accountId\":\"$ACC2_ID\"}")
K3_ID=$(new_item "{\"label\":\"K3\",\"accountId\":\"$ACC2_ID\"}")
K4_ID=$(new_item "{\"label\":\"K4\",\"accountId\":\"$ACC2_ID\"}")
K5_ID=$(new_item "{\"label\":\"K5\",\"accountId\":\"$ACC2_ID\"}")
K6_ID=$(new_item "{\"label\":\"K6\",\"accountId\":\"$ACC2_ID\"}")
wait_items "$ACC2_URL" "items" "A1-renamed,B3,K1,K2,K3,K4,K5,K6" && ok "burst converged to the exact set under 3 workers" || bad "workers-3 burst lost an element"

title "13.3 Interleaved delete + rename + move across workers → exact final sets"
curl -sS -o /dev/null -X DELETE "$BASE/qa/items/$K2_ID"
curl -sS -o /dev/null -X PATCH "$BASE/qa/items/$K3_ID" -H "Content-Type: application/json" --data '{"label":"K3-r"}'
curl -sS -o /dev/null -X PATCH "$BASE/qa/items/$K4_ID" -H "Content-Type: application/json" --data "{\"accountId\":\"$ACC_ID\"}"
wait_items "$ACC2_URL" "items" "A1-renamed,B3,K1,K3-r,K5,K6" && ok "acct-002 settled exactly (delete+rename+move interleaved on 3 workers)" || bad "acct-002 items wrong under workers-3 interleave"
wait_items "$ACC_URL" "items" "B1,B4,K4,W1,W2,W3,W4,W5" && ok "acct-001 gained exactly the moved K4" || bad "acct-001 items wrong after cross-worker move"

##############################################################################
sec "Cleanup + Summary"
##############################################################################
reset_domain
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
