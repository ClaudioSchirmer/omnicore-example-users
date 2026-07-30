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
  qa_db_exec "DELETE FROM qa_account_lines;" 2>/dev/null || true
  qa_db_exec "DELETE FROM qa_accounts;" 2>/dev/null || true
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
# jchild URL CHILD_SEG ENRICH -> sorted labels of data.<child>[].<enrich>.label
# (the EmbedInChild view: each child element carries an enriched 1:1 sub-doc; a
# line whose FK is null/unresolved contributes the empty label "").
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
# wait_child URL CHILD_SEG ENRICH EXPECTED_CSV — poll until the enriched labels match
wait_child() {
  local deadline=$(( $(date +%s) + QA_CDC_DEADLINE )) got=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    got=$(jchild "$1" "$2" "$3"); [ "$got" = "$4" ] && return 0; sleep 1
  done
  echo "    (last seen: '$got', wanted: '$4')" >&2; return 1
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
title "1.1 Two featured items (no FK — referenced 1:1 only) + two line items (EmbedInChild sources)"
FA_ID=$(new_item '{"label":"FA-featured"}')
FC_ID=$(new_item '{"label":"FC-featured"}')
# L1/L2 are DEDICATED items referenced only by catalog LINES via EmbedInChild —
# kept apart from the FA/FC/A*/C* items the other sections mutate, so the
# EmbedInChild assertions below stay stable until this section deliberately
# renames/deletes them.
L1_ID=$(new_item '{"label":"L1-line"}')
L2_ID=$(new_item '{"label":"L2-line"}')
# M1/M2 are the account base-child line sources (EmbedInChild on the SharedBaseView).
M1_ID=$(new_item '{"label":"M1-line"}')
M2_ID=$(new_item '{"label":"M2-line"}')
{ [ -n "$FA_ID" ] && [ -n "$FC_ID" ] && [ -n "$L1_ID" ] && [ -n "$L2_ID" ] && [ -n "$M1_ID" ] && [ -n "$M2_ID" ]; } && ok "featured + line items created (account=$FA_ID catalog=$FC_ID cat-lines=$L1_ID,$L2_ID acc-lines=$M1_ID,$M2_ID)" || { bad "featured/line item create failed"; }

title "1.2 Shared-base account (featuredItemId=FA) + a second account (move target) + normal catalog (featuredItemId=FC)"
# acct-001 is created WITH base-child lines: two enriched (M1, M2) + one null-FK.
ACC_ID=$(post_json "$BASE/qa/accounts" "{\"accountRef\":\"acct-001\",\"displayName\":\"Primary Account\",\"holderName\":\"Ada Lovelace\",\"featuredItemId\":\"$FA_ID\",\"lines\":[{\"itemId\":\"$M1_ID\",\"note\":\"m-1\"},{\"itemId\":\"$M2_ID\",\"note\":\"m-2\"},{\"note\":\"m-null\"}]}" | jid)
ACC2_ID=$(post_json "$BASE/qa/accounts" '{"accountRef":"acct-002","displayName":"Second Account","holderName":"Grace Hopper"}' | jid)
# The catalog is created WITH native child lines: two reference items (L1, L2)
# enriched via EmbedInChild, plus one line with NO itemId (proves a null FK
# yields a null enrichment, never a leak).
CAT_ID=$(post_json "$BASE/qa/catalogs" "{\"name\":\"Summer Collection\",\"featuredItemId\":\"$FC_ID\",\"lines\":[{\"itemId\":\"$L1_ID\",\"note\":\"line-1\"},{\"itemId\":\"$L2_ID\",\"note\":\"line-2\"},{\"note\":\"line-null\"}]}" | jid)
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

title "2.2b Embed-segment ID visible — the external mirror embed carries its source's id"
# The original topic: an embedded segment's identity. The upstream_items mirror
# projects id (filter allowlists it), so ItemSegmentOutput.ID binds on both the 1:1
# (featuredItem) and every 1:N (items) element. Guaranteed resolved by 2.1/2.2 above.
curl -sS -o "$GET_TMP" "$ACC_URL"
CHK=$(python3 -c '
import sys, json
acc = json.load(open(sys.argv[1])).get("data", {})
feat = acc.get("featuredItem") or {}
items = acc.get("items") or []
feat_id = bool(feat.get("id"))
items_id = bool(items) and all(bool(it.get("id")) for it in items)
print("OK" if (feat_id and items_id) else "BAD feat_id=%s items=%d items_id=%s" % (feat_id, len(items), items_id))
' "$GET_TMP")
[ "$CHK" = "OK" ] \
  && ok "featuredItem.id AND items[].id present — the external mirror embed exposes its source id" \
  || bad "embed-segment id not visible in DTO: $CHK"

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

title "4.4b Embed 1:1 segment IDENTITY (id) — queryable + strippable like any field (external id promoted from _id)"
# The mirror-embed segment's id is the external source identity the read side
# promotes from `_id`. It must behave like any field: row-select via filter AND
# obey ?fields=. (Exercised here, before §10.2 deletes FC and nulls the segment.)
# Shared-base view (account) counterpart — the SAME mirror-segment id path:
lget "$ACCLIST" "featuredItem.id=$FA_ID"; { [ "$(lcount)" = "1" ] && [ "$(lfield 0 accountRef)" = "acct-001" ]; } && ok "account ?featuredItem.id=<itemId> → selects the account (mirror-segment id queryable, shared-base view)" || bad "mirror-segment id not queryable on shared-base (count=$(lcount))"
# Normal view (catalog):
lget "$CATLIST" "featuredItem.id=$FC_ID";       [ "$(lcount)" = "1" ] && ok "catalog ?featuredItem.id=<itemId> → selects the catalog (mirror-segment id is queryable)" || bad "mirror-segment id not queryable (count=$(lcount))"
lget "$CATLIST" "featuredItem.id=no-such-item"; [ "$(lcount)" = "0" ] && ok "?featuredItem.id=bogus → 0 rows (no false positive)" || bad "mirror-segment id filter false positive (count=$(lcount))"
lget "$CATLIST" "name=Summer Collection" "fields=name,featuredItem.label"
CHK=$(python3 -c '
import sys, json
d = json.load(open(sys.argv[1])).get("data") or []
feat = (d[0] if d else {}).get("featuredItem") or {}
# the mirror segment carries label but NOT id when id was not requested
print("OK" if ("label" in feat and "id" not in feat) else "BAD %s" % feat)' "$GET_TMP")
[ "$CHK" = "OK" ] && ok "?fields=…featuredItem.label DROPS the mirror-segment id (stripped like any field)" || bad "mirror-segment id leaked past ?fields=: $CHK"
lget "$CATLIST" "name=Summer Collection" "fields=name,featuredItem.id"
CHK=$(python3 -c '
import sys, json
d = json.load(open(sys.argv[1])).get("data") or []
feat = (d[0] if d else {}).get("featuredItem") or {}
print("OK" if feat.get("id") == sys.argv[2] else "BAD %s" % feat)' "$GET_TMP" "$FC_ID")
[ "$CHK" = "OK" ] && ok "?fields=…featuredItem.id KEEPS the mirror-segment id (==$FC_ID)" || bad "mirror-segment id dropped when requested: $CHK"

title "4.4c Embed 1:N segment IDENTITY (items[].id) — the SAME external id path as the 1:1"
# The 1:N array elements carry the external source id too (promoted from each
# element's `_id`). Row-select via filter AND obey ?fields=, on both view kinds.
ACC_IT=$(curl -sS "$ACC_URL" | python3 -c 'import sys,json; its=(json.load(sys.stdin).get("data") or {}).get("items") or []; print(its[0].get("id","") if its else "")')
CAT_IT=$(curl -sS "$CAT_URL" | python3 -c 'import sys,json; its=(json.load(sys.stdin).get("data") or {}).get("items") or []; print(its[0].get("id","") if its else "")')
{ [ -n "$ACC_IT" ] && [ -n "$CAT_IT" ]; } || bad "could not read a 1:N items[].id from the full docs (acc='$ACC_IT' cat='$CAT_IT')"
lget "$ACCLIST" "items.id=$ACC_IT"; { [ "$(lcount)" = "1" ] && [ "$(lfield 0 accountRef)" = "acct-001" ]; } && ok "account ?items.id=<itemId> → selects the account (1:N mirror-segment id queryable, shared-base)" || bad "1:N mirror id not queryable on shared-base (count=$(lcount))"
lget "$CATLIST" "items.id=$CAT_IT"; [ "$(lcount)" = "1" ] && ok "catalog ?items.id=<itemId> → selects the catalog (1:N mirror-segment id queryable, normal view)" || bad "1:N mirror id not queryable on normal view (count=$(lcount))"
lget "$ACCLIST" "items.id=no-such-item"; [ "$(lcount)" = "0" ] && ok "?items.id=bogus → 0 rows (no false positive)" || bad "1:N mirror id filter false positive (count=$(lcount))"
lget "$ACCLIST" "accountRef=acct-001" "fields=displayName,items.label"
CHK=$(python3 -c '
import sys, json
d = json.load(open(sys.argv[1])).get("data") or []
its = (d[0] if d else {}).get("items") or []
# every 1:N element carries label but NOT id when id was not requested
ok = bool(its) and all(("label" in it) and ("id" not in it) for it in its)
print("OK" if ok else "BAD %s" % (its[0] if its else None))' "$GET_TMP")
[ "$CHK" = "OK" ] && ok "?fields=…items.label DROPS the 1:N segment id (stripped like any field)" || bad "1:N segment id leaked past ?fields=: $CHK"
lget "$ACCLIST" "accountRef=acct-001" "fields=displayName,items.id"
CHK=$(python3 -c '
import sys, json
d = json.load(open(sys.argv[1])).get("data") or []
its = (d[0] if d else {}).get("items") or []
ok = bool(its) and all(bool(it.get("id")) for it in its)
print("OK" if ok else "BAD %s" % (its[0] if its else None))' "$GET_TMP")
[ "$CHK" = "OK" ] && ok "?fields=…items.id KEEPS the 1:N segment id" || bad "1:N segment id dropped when requested: $CHK"

title "4.4d SharedBaseView root id — queryable + strippable (the base id, == the view _id)"
# The shared-base root id is a stored physical column (own[pk] in payload_project),
# NOT an _id-only value — so it obeys filter + ?fields= exactly like the normal view.
lget "$ACCLIST" "id=$ACC_ID"; { [ "$(lcount)" = "1" ] && [ "$(lfield 0 accountRef)" = "acct-001" ]; } && ok "account ?id=<baseId> → selects the account (shared-base root id queryable)" || bad "shared-base root id not queryable (count=$(lcount))"
lget "$ACCLIST" "id=no-such-account"; [ "$(lcount)" = "0" ] && ok "?id=bogus → 0 rows (no false positive)" || bad "shared-base root id filter false positive (count=$(lcount))"
lget "$ACCLIST" "accountRef=acct-001" "fields=displayName"; [ "$(lhaskey 0 id)" = n ] && ok "?fields=displayName DROPS the shared-base root id" || bad "shared-base root id leaked past ?fields=displayName"
lget "$ACCLIST" "accountRef=acct-001" "fields=id,displayName"; { [ "$(lhaskey 0 id)" = y ] && [ "$(lfield 0 id)" = "$ACC_ID" ]; } && ok "?fields=id,displayName KEEPS the shared-base root id (==$ACC_ID)" || bad "shared-base root id dropped when requested"

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
sec "14. EmbedInChild — 1:1 enrichment of a native child array (qa_catalog_view)"
##############################################################################
# The catalog was seeded in §1 with THREE native child lines: two referencing
# dedicated items (L1, L2) enriched via EmbedInChild, and one with NO itemId. It
# has since survived TWO rebuilds (§8 full blue-green, §11 online) — so a correct
# compose here ALSO proves the EmbedInChild enrichment survives the rebuild path
# (batched ComposeBatch + applyChildEmbeds). L1/L2 were untouched by §5-§13.

title "14.1 Compose — each line's item resolves; the null-FK line stays null (no leak)"
wait_child "$CAT_URL" "catalogLines" "item" ",L1-line,L2-line" \
  && ok "catalogLines[].item = [L1-line, L2-line, (null)] — enriched, null-FK line null, survived 2 rebuilds" \
  || bad "catalogLines enrichment wrong"

title "14.1b Identity at EVERY level — child ID + ParentID + embed-segment ID (new-field visibility)"
# The read side projects identity at EVERY document level, and the DTO declares it:
#   - each native child element carries its own ID (child's physical PK column) AND
#     ParentID (the aggregate FK column catalog_id, exposed read-only);
#   - each embed segment (featuredItem 1:1, items[] 1:N — the upstream_items mirror)
#     carries its own ID (the segment source's PK). This is the original topic: a
#     mirror embed's id, now visible.
curl -sS -o "$GET_TMP" "$CAT_URL"
CHK=$(python3 -c '
import sys, json
cat = json.load(open(sys.argv[1])).get("data", {})
pid = sys.argv[2]
lines = cat.get("catalogLines") or []
line_parent = all(l.get("parentId") == pid for l in lines)
line_id = all(bool(l.get("id")) for l in lines)
feat = cat.get("featuredItem")
items = cat.get("items") or []
feat_ok = (feat is None) or bool(feat.get("id"))          # 1:1 embed id, when resolved
items_ok = all(bool(it.get("id")) for it in items)        # every 1:N embed element id
ok_all = bool(lines) and line_parent and line_id and feat_ok and items_ok
print("OK" if ok_all else "BAD lines=%d lp=%s li=%s feat=%s items=%s(%d)" % (
    len(lines), line_parent, line_id, feat_ok, items_ok, len(items)))
' "$GET_TMP" "$CAT_ID")
[ "$CHK" = "OK" ] \
  && ok "identity visible at every level — child .id + .parentId (==$CAT_ID) AND embed-segment .id (featuredItem/items)" \
  || bad "new identity fields not fully visible in DTO: $CHK"

title "14.2 Read — 2-level nested filter into the enriched child (catalogLines.item.label)"
lget "$CATLIST" "catalogLines.item.label=L1-line"; [ "$(lcount)" = "1" ] && ok "?catalogLines.item.label=L1-line → 1 row (nested enriched-field filter)" || bad "nested enriched filter wrong (count=$(lcount))"
lget "$CATLIST" "catalogLines.item.label=nope";    [ "$(lcount)" = "0" ] && ok "?catalogLines.item.label=nope → 0 rows (no false positive)" || bad "nested enriched filter false positive"

title "14.3 Read — ?fields= keeps/drops the enriched child segment"
lget "$CATLIST" "name=Summer Collection" "fields=name"; { [ "$(lhaskey 0 name)" = y ] && [ "$(lhaskey 0 catalogLines)" = n ]; } && ok "?fields=name drops catalogLines" || bad "sparse projection did not drop catalogLines"
lget "$CATLIST" "name=Summer Collection" "fields=name,catalogLines.item.label"; [ "$(lhaskey 0 catalogLines)" = y ] && ok "?fields=name,catalogLines.item.label keeps the enriched child" || bad "sparse projection dropped the requested enriched child"

title "14.3b Identity (id/parentId) obeys the SAME rules as any field — FILTER, SORT and ?fields="
# The projected identity is a real, queryable, strippable field at every level —
# not a read-only decoration. Root id + child id/parentId are stored physical
# columns; the mirror-embed segment id is the external identity promoted from _id.
# --- root id: physical column → queryable AND strippable ---
lget "$CATLIST" "id=$CAT_ID";          { [ "$(lcount)" -ge 1 ] && [ "$(lfield 0 id)" = "$CAT_ID" ]; } && ok "?id=<catId> → matches (root id is queryable)" || bad "root id not queryable (count=$(lcount))"
lget "$CATLIST" "id=no-such-catalog";  [ "$(lcount)" = "0" ] && ok "?id=bogus → 0 rows (no false positive)" || bad "root id filter false positive (count=$(lcount))"
lget "$CATLIST" "name=Summer Collection" "sort=id";  [ "$(lcount)" -ge 1 ] && ok "?sort=id accepted (root id is sortable)" || bad "?sort=id rejected/empty (count=$(lcount))"
lget "$CATLIST" "name=Summer Collection" "sort=-id"; [ "$(lcount)" -ge 1 ] && ok "?sort=-id accepted (root id is sortable desc)" || bad "?sort=-id rejected/empty (count=$(lcount))"
lget "$CATLIST" "name=Summer Collection" "fields=name";    [ "$(lhaskey 0 id)" = n ] && ok "?fields=name DROPS root id (stripped like any field)" || bad "root id leaked past ?fields=name"
lget "$CATLIST" "name=Summer Collection" "fields=id,name"; { [ "$(lhaskey 0 id)" = y ] && [ "$(lfield 0 id)" = "$CAT_ID" ]; } && ok "?fields=id,name KEEPS root id" || bad "root id dropped when explicitly requested"
# --- child catalogLines: id + parentId are stored physical columns ---
lget "$CATLIST" "catalogLines.parentId=$CAT_ID"; [ "$(lcount)" -ge 1 ] && ok "?catalogLines.parentId=<catId> → matches (child parentId is queryable)" || bad "child parentId not queryable (count=$(lcount))"
lget "$CATLIST" "catalogLines.parentId=no-such-parent"; [ "$(lcount)" = "0" ] && ok "?catalogLines.parentId=bogus → 0 rows (no false positive)" || bad "child parentId filter false positive (count=$(lcount))"
lget "$CATLIST" "name=Summer Collection" "fields=name,catalogLines.note"
CHK=$(python3 -c '
import sys, json
d = json.load(open(sys.argv[1])).get("data") or []
row = d[0] if d else {}
lines = row.get("catalogLines") or []
# every line carries note but NEITHER id NOR parentId when they were not requested
ok = bool(lines) and all(("note" in l) and ("id" not in l) and ("parentId" not in l) for l in lines)
print("OK" if ok else "BAD lines=%d sample=%s" % (len(lines), lines[0] if lines else None))' "$GET_TMP")
[ "$CHK" = "OK" ] && ok "?fields=…catalogLines.note DROPS child id + parentId (stripped like any field)" || bad "child id/parentId leaked past ?fields=: $CHK"
lget "$CATLIST" "name=Summer Collection" "fields=name,catalogLines.id,catalogLines.parentId"
CHK=$(python3 -c '
import sys, json
d = json.load(open(sys.argv[1])).get("data") or []
row = d[0] if d else {}
cid = sys.argv[2]
lines = row.get("catalogLines") or []
# every line carries its own id AND parentId (== the catalog id) when requested
ok = bool(lines) and all(bool(l.get("id")) and l.get("parentId") == cid for l in lines)
print("OK" if ok else "BAD lines=%d sample=%s" % (len(lines), lines[0] if lines else None))' "$GET_TMP" "$CAT_ID")
[ "$CHK" = "OK" ] && ok "?fields=…catalogLines.id,parentId KEEPS them (parentId==$CAT_ID)" || bad "child id/parentId dropped when requested: $CHK"
# NOTE: the mirror-embed segment id (featuredItem) is exercised in §4.4b, while
# the featured item is still attached — §10.2 deletes it, nulling the segment.

title "14.4 Export — CSV walks the enriched child branch"
curl -sS -o "$GET_TMP" "$CATLIST.csv"; grep -q "L1-line" "$GET_TMP" && ok "catalogs.csv carries an enriched child item label" || bad "catalogs CSV missing the enriched child data"

title "14.5 Ripple — rename an enriched item → the child line's item ripples (no write to the catalog)"
curl -sS -o /dev/null -X PATCH "$BASE/qa/items/$L1_ID" -H "Content-Type: application/json" --data '{"label":"L1-renamed"}'
wait_child "$CAT_URL" "catalogLines" "item" ",L1-renamed,L2-line" && ok "catalogLines[].item rippled to L1-renamed (consult-guarded recompose)" || bad "EmbedInChild rename ripple failed"

title "14.6 Ripple — delete an enriched item → that line's enrichment clears to null"
curl -sS -o /dev/null -X DELETE "$BASE/qa/items/$L2_ID"
wait_child "$CAT_URL" "catalogLines" "item" ",,L1-renamed" && ok "deleted item cleared its line's enrichment to null (cascade + recompose)" || bad "EmbedInChild delete ripple failed"

##############################################################################
sec "15. EmbedInChild on a SharedBaseView — enriched BASE child (qa_accounts_view)"
##############################################################################
# acct-001 was seeded in §1 with three base-child lines (M1, M2 enriched + a
# null-FK line) and survived the §8/§11 rebuilds. Same facets as §14, on a
# SharedBaseView: the base child materializes at the ROOT of the person doc
# (accountLines[]), each element enriched 1:1 via EmbedInChild.

title "15.1 Compose — base-child lines enriched at the person-document root; null-FK stays null"
wait_child "$ACC_URL" "accountLines" "item" ",M1-line,M2-line" \
  && ok "accountLines[].item = [M1-line, M2-line, (null)] on the shared-base view (survived rebuilds)" \
  || bad "accountLines enrichment wrong"

title "15.2 Read — nested filter into the enriched base child (accountLines.item.label)"
lget "$ACCLIST" "accountLines.item.label=M1-line"; { [ "$(lcount)" = "1" ] && [ "$(lfield 0 accountRef)" = "acct-001" ]; } && ok "?accountLines.item.label=M1-line → acct-001 (nested enriched filter, shared-base)" || bad "shared-base nested enriched filter wrong"

title "15.3 Read — ?fields= keeps/drops the enriched base-child segment"
lget "$ACCLIST" "accountRef=acct-001" "fields=displayName"; [ "$(lhaskey 0 accountLines)" = n ] && ok "?fields=displayName drops accountLines" || bad "sparse projection did not drop accountLines"
lget "$ACCLIST" "accountRef=acct-001" "fields=displayName,accountLines.item.label"; [ "$(lhaskey 0 accountLines)" = y ] && ok "?fields=…,accountLines.item.label keeps the enriched base child" || bad "sparse projection dropped the requested enriched base child"

title "15.4 Ripple — rename an enriched item → the base-child line ripples"
curl -sS -o /dev/null -X PATCH "$BASE/qa/items/$M1_ID" -H "Content-Type: application/json" --data '{"label":"M1-renamed"}'
wait_child "$ACC_URL" "accountLines" "item" ",M1-renamed,M2-line" && ok "accountLines[].item rippled to M1-renamed (shared-base recompose)" || bad "shared-base EmbedInChild rename ripple failed"

title "15.5 Ripple — delete an enriched item → that base-child line's enrichment clears to null"
curl -sS -o /dev/null -X DELETE "$BASE/qa/items/$M2_ID"
wait_child "$ACC_URL" "accountLines" "item" ",,M1-renamed" && ok "deleted item cleared its base-child line's enrichment to null" || bad "shared-base EmbedInChild delete ripple failed"

##############################################################################
sec "Cleanup + Summary"
##############################################################################
reset_domain
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
