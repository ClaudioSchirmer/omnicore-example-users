#!/usr/bin/env bash
# ComposedView suite — READ-TIME composition (via the qa-only Gadget + GadgetNote).
#
# `gadgets_full` is a query.ComposedView: never materialized, never synced — no
# collection, no Version, no recompose. A read against it reads the `gadgets`
# view as PRIMARY (rows, sort, pagination, total, cursors) and enriches each
# item by key, in batch, from two legs: `upstreamMirror` (1:1 EXTERNAL — the
# locally materialized upstream_gadgets projection; primary holds the FK) and
# `notes` (1:N INTERNAL — the gadget_notes view; leg holds the FK; OrderBy text,
# MaxLinkManyLimit 3). Contrast with upstream_composition.sh: same mirror data,
# but there the composition is MATERIALIZED at write time (Embed →
# gadgets_embedded); here it is joined at read time.
#
# Asserts: (1) list + by-id reads enrich both legs, Go-keyed segments on the
# wire; (2) LEFT semantics — mirror null/absent when the upstream doc is gone,
# notes [] when none; (3) row filters select rows, segment filters only shape
# the segment (R2); (4) ?sort into a segment → 400 (R3); (5) MaxLinkManyLimit
# truncates deterministically in the declared order (first 3 by text); (6) the
# archived gate is per leg — an archived note leaves the segment on default
# reads, returns under ?includeArchived (the mirror leg has no soft-delete: the
# knob is a no-op there); (7) keyset cursors round-trip WITH a segment filter,
# and a changed segment filter invalidates the cursor (composed context hash);
# (8) ?onlyTotal short-circuits; (9) ?fields= projects into segments; (10) the
# per-leg authorization overlay (R9): the by-id query's ToCriteria pins
# Notes.Kind=public, so an internal note NEVER surfaces on the composed by-id
# read while staying visible on the leg's own list; (11) CSV export renders the
# leg branches; (12) the same composed name serves GraphQL (gadgetsFull);
# (13) primary knobs flow through unchanged — ?search= (text index, enriched
# hits), the primary MaxLimit ceiling (?limit over it → 400), empty pages,
# ?before= backward navigation; (14) 1:1 segment filters (null the sub-doc,
# never the row), AND-ed segment operators, ?fields= into the mirror, and the
# list/by-id overlay CONTRAST on kind=internal; (15) an archived PRIMARY 404s
# by id and leaves the list, ?includeArchived serves it with legs, unarchive
# restores; (16) CSV ?fields= pruning + XLSX; (17) GraphQL where + Relay
# after-cursor navigation; (18) a SECURITY OVERLAY in ToCriteria (row gate
# Status=active, the tenant-gate seam) filters rows on list AND by-id while
# cursor navigation keeps round-tripping — the framework's post-ToCriteria
# authoritative cursor validation, i.e. a dev adding a security filter can
# never break pagination.
#
# Deliberately NOT covered here (unit-covered in the framework; not exercisable
# against a running binary): boot-fatal composed declarations (they are Go
# code, not config — a broken declaration never boots) and the
# query.maxLinkManyLimit YAML cascade (the fixture pins the per-link value so
# truncation is deterministic).
#
# Prereqs: docker compose up + the OUTBOX Debezium connector registered.
# Self-managed server lifecycle. Dialect-driven via _backend.sh.
#
# Run from anywhere:  bash qa/composed_view.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-composed-view-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-composed-view-${BACKEND:-postgres}.log"
QA_YAML="$REPO_ROOT/microservice.qa.yaml"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
cleanup() { if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi; kill_port "${HTTP_PORT:-8080}"; docker exec omnicore-qa-mongo mongosh "$QA_MONGO_DB" --quiet --eval "db.gadgets.drop(); db.gadget_notes.drop(); db.gadgets_hot.drop(); db.gadgets_capped.drop(); db.gadgets_embedded.drop(); db.upstream_gadgets.drop()" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

mongoq() { docker exec omnicore-qa-mongo mongosh "$QA_MONGO_DB" --quiet --eval "$1" 2>/dev/null | tail -1 | tr -d ' '; }

jget() {  # $1 = python expression over parsed json `d`, $2 = json file
  python3 -c '
import sys, json
expr, fn = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(fn))
except Exception:
    print(""); sys.exit()
try:
    v = eval(expr)
except Exception:
    v = ""
print("" if v is None else v)' "$1" "$2" 2>/dev/null
}

##############################################################################
sec "0. Build qa binary + boot with qa.yaml + seed"
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
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/health" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready" || { bad "server not ready"; tail -n 40 "$SERVER_LOG"; exit 1; }

# Prove the CDC pipeline is hot (consumer groups joined, Debezium task live)
# BEFORE any per-step deadline starts counting; the clean-baseline step below
# sweeps the sentinel. Non-fatal — see qa/_backend.sh.
qa_cdc_warmup_gadget

title "0.4 Clean baseline"
qa_db_exec "DELETE FROM gadget_journal;" 2>/dev/null || true
qa_db_exec "DELETE FROM gadget_notes;" 2>/dev/null || true
qa_db_exec "DELETE FROM gadgets;"
docker exec omnicore-qa-mongo mongosh "$QA_MONGO_DB" --quiet --eval "db.gadgets.deleteMany({}); db.gadget_notes.deleteMany({}); db.upstream_gadgets.deleteMany({})" >/dev/null 2>&1 || true
sleep 1
ok "clean baseline"

title "0.5 Seed gadgets A + B and notes (CDC materializes the views)"
gadget() {  # $1 code, $2 name → prints gadget id
  curl -sS -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" \
    --data "{\"code\":\"$1\",\"name\":\"$2\",\"category\":\"tools\",\"status\":\"active\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null
}
GA=$(gadget "CV-001" "Composed One")
GB=$(gadget "CV-002" "Composed Two")
{ [ -n "$GA" ] && [ -n "$GB" ]; } && ok "gadgets created (A=$GA B=$GB)" || { bad "gadget creation failed"; exit 1; }

note() {  # $1 gadget id, $2 text, $3 kind → prints note id
  curl -sS -X POST "$BASE/qa/gadget-notes" -H "Content-Type: application/json" \
    --data "{\"gadgetId\":\"$1\",\"text\":\"$2\",\"kind\":\"$3\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null
}
# A: four public notes → the cap (3, ordered by text) must truncate d4 away.
N1=$(note "$GA" "a1" public); N2=$(note "$GA" "b2" public)
N3=$(note "$GA" "c3" public); N4=$(note "$GA" "d4" public)
# B: one public + one internal → the by-id overlay (R9) must hide the internal.
NB=$(note "$GB" "b-pub" public); NI=$(note "$GB" "x-internal" internal)
{ [ -n "$N1" ] && [ -n "$N4" ] && [ -n "$NB" ] && [ -n "$NI" ]; } && ok "notes created" || bad "note creation failed"

title "0.6 Wait for CDC (gadgets ×2, gadget_notes ×6, upstream mirrors ×2)"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); synced=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  g=$(mongoq "db.gadgets.countDocuments({})")
  n=$(mongoq "db.gadget_notes.countDocuments({})")
  u=$(mongoq "db.upstream_gadgets.countDocuments({})")
  [ "${g:-0}" = "2" ] && [ "${n:-0}" = "6" ] && [ "${u:-0}" = "2" ] && { synced=ok; break; }
  sleep 1
done
[ "$synced" = ok ] && ok "views materialized (gadgets=2 notes=6 mirrors=2)" || { bad "CDC never converged (g=$g n=$n u=$u)"; tail -n 30 "$SERVER_LOG"; exit 1; }

##############################################################################
sec "1. Composed list + by-id enrich both legs (nothing was materialized)"
##############################################################################
title "1.1 gadgets_full is NOT a Mongo collection (read-time only)"
EXISTS=$(mongoq "db.getCollectionNames().includes('gadgets_full')")
[ "$EXISTS" = "false" ] && ok "no gadgets_full collection exists — the composition is read-time" || bad "a gadgets_full collection exists ($EXISTS)"

title "1.2 GET /qa/gadgets-full lists both gadgets with mirror + notes window"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?sort=code"
COUNT=$(jget 'len(d["data"])' /tmp/qa-cv.json)
[ "$COUNT" = "2" ] && ok "2 composed items" || { bad "expected 2 items, got '$COUNT'"; cat /tmp/qa-cv.json; }
MCODE=$(jget 'd["data"][0]["upstreamMirror"]["code"]' /tmp/qa-cv.json)
[ "$MCODE" = "CV-001" ] && ok "1:1 external leg attached (upstreamMirror.code=CV-001)" || bad "mirror missing on item A ('$MCODE')"
TEXTS=$(jget '",".join(n["text"] for n in d["data"][0]["notes"])' /tmp/qa-cv.json)
[ "$TEXTS" = "a1,b2,c3" ] && ok "1:N leg truncated deterministically: first 3 by text (d4 dropped)" || bad "notes window wrong: '$TEXTS'"
BTEXTS=$(jget '",".join(n["text"] for n in d["data"][1]["notes"])' /tmp/qa-cv.json)
# The LIST query carries NO overlay by design — internal notes are visible
# here; the by-id read (overlay Notes.Kind=public) is the R9 counterpart.
[ "$BTEXTS" = "b-pub,x-internal" ] && ok "item B window ordered by text, overlay-free on the list ($BTEXTS)" || bad "item B notes window wrong: '$BTEXTS'"
TOTAL=$(jget 'd["pagination"]["total"]' /tmp/qa-cv.json)
[ "$TOTAL" = "2" ] && ok "total is the primary's (2)" || bad "total wrong: '$TOTAL'"

title "1.3 GET /qa/gadgets-full/:id (A) — by-id composed read"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/$GA"
MC=$(jget 'd["data"]["upstreamMirror"]["code"]' /tmp/qa-cv.json)
TX=$(jget '",".join(n["text"] for n in d["data"]["notes"])' /tmp/qa-cv.json)
[ "$MC" = "CV-001" ] && ok "by-id carries the mirror" || bad "by-id mirror missing ('$MC')"
[ "$TX" = "a1,b2,c3" ] && ok "by-id notes window matches the declared order + cap" || bad "by-id notes wrong: '$TX'"

##############################################################################
sec "2. Row filter vs segment filter (R2) + segment sort rejection (R3)"
##############################################################################
title "2.1 Row filter selects rows: ?code=CV-001 → 1 item"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?code=CV-001"
COUNT=$(jget 'len(d["data"])' /tmp/qa-cv.json)
[ "$COUNT" = "1" ] && ok "row filter selected 1 gadget" || bad "row filter returned '$COUNT'"

title "2.2 Segment filter shapes the segment, never the rows: ?notes.text=a1 → 2 items"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?notes.text=a1&sort=code"
COUNT=$(jget 'len(d["data"])' /tmp/qa-cv.json)
[ "$COUNT" = "2" ] && ok "both gadgets still listed (segment filters never select rows)" || bad "segment filter selected rows: '$COUNT'"
ATX=$(jget '",".join(n["text"] for n in d["data"][0]["notes"])' /tmp/qa-cv.json)
BN=$(jget 'len(d["data"][1].get("notes") or [])' /tmp/qa-cv.json)
[ "$ATX" = "a1" ] && ok "A's segment filtered to [a1]" || bad "A's segment wrong: '$ATX'"
[ "$BN" = "0" ] && ok "B's segment emptied (no matching note) — LEFT semantics keep the row" || bad "B's segment wrong: $BN"

title "2.3 ?sort=notes.text → 400 (segment order is declared on the link, not wire-set)"
ST=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/qa/gadgets-full/?sort=notes.text")
[ "$ST" = "400" ] && ok "segment sort rejected with 400" || bad "segment sort returned $ST"

##############################################################################
sec "3. Keyset cursors carry the COMPOSED context (segment filters included)"
##############################################################################
title "3.1 Page 1 with a segment filter → next_cursor"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?notes.text=a1&sort=code&limit=1"
C1=$(jget 'd["data"][0]["code"]' /tmp/qa-cv.json)
CUR=$(jget 'd["pagination"]["next_cursor"]' /tmp/qa-cv.json)
{ [ "$C1" = "CV-001" ] && [ -n "$CUR" ]; } && ok "page 1 = CV-001 with a cursor" || bad "page 1 wrong (code='$C1' cursor='${CUR:0:12}…')"

title "3.2 Same query + after → page 2"
ENC=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$CUR")
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?notes.text=a1&sort=code&limit=1&after=$ENC"
C2=$(jget 'd["data"][0]["code"]' /tmp/qa-cv.json)
[ "$C2" = "CV-002" ] && ok "cursor round-tripped to CV-002" || { bad "page 2 wrong ('$C2')"; cat /tmp/qa-cv.json; }

title "3.3 Same cursor with a CHANGED segment filter → 400 (context bound)"
ST=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/qa/gadgets-full/?notes.text=b2&sort=code&limit=1&after=$ENC")
[ "$ST" = "400" ] && ok "changed segment filter invalidates the cursor" || bad "stale cursor accepted ($ST)"

##############################################################################
sec "4. onlyTotal + fields projection into segments"
##############################################################################
title "4.1 ?onlyTotal=true → count-only envelope, no leg work"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?onlyTotal=true"
TOTAL=$(jget 'd["pagination"]["total"]' /tmp/qa-cv.json)
HASDATA=$(jget '"data" in d' /tmp/qa-cv.json)
{ [ "$TOTAL" = "2" ] && [ "$HASDATA" = "False" ]; } && ok "count-only short-circuit (total=2, no data)" || bad "onlyTotal wrong (total='$TOTAL' data=$HASDATA)"

title "4.2 ?fields=code,notes.text → sparse render into the segment"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?fields=code,notes.text&sort=code"
ITEM=$(jget 'sorted(d["data"][0].keys())' /tmp/qa-cv.json)
[ "$ITEM" = "['code', 'notes']" ] && ok "item carries only code + notes" || bad "unexpected item keys: $ITEM"
NKEYS=$(jget 'sorted(d["data"][0]["notes"][0].keys())' /tmp/qa-cv.json)
[ "$NKEYS" = "['text']" ] && ok "note entries carry only text" || bad "unexpected note keys: $NKEYS"

##############################################################################
sec "5. Archived gate per leg (R8) + LEFT semantics (R5)"
##############################################################################
title "5.1 Archive note b-pub → B's default segment empties; ?includeArchived restores it"
curl -sS -o /dev/null -X PATCH "$BASE/qa/gadget-notes/$NB/archive"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); gated=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/$GB"
  BN=$(jget 'len(d["data"]["notes"])' /tmp/qa-cv.json)
  [ "$BN" = "0" ] && { gated=ok; break; }
  sleep 1
done
[ "$gated" = ok ] && ok "archived note left the default segment (internal one is overlay-hidden)" || bad "archived note still in the segment"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/$GB?includeArchived=true"
BTX=$(jget '",".join(n["text"] for n in d["data"]["notes"])' /tmp/qa-cv.json)
MB=$(jget 'd["data"]["upstreamMirror"]["code"]' /tmp/qa-cv.json)
[ "$BTX" = "b-pub" ] && ok "?includeArchived surfaces the archived note (overlay still hides internal)" || bad "includeArchived segment wrong: '$BTX'"
[ "$MB" = "CV-002" ] && ok "the mirror leg has no soft-delete — the knob is a no-op there" || bad "mirror broken under includeArchived ('$MB')"

title "5.2 Remove B's upstream doc → mirror is LEFT-null; the row survives"
docker exec omnicore-qa-mongo mongosh "$QA_MONGO_DB" --quiet --eval "db.upstream_gadgets.deleteOne({code:'CV-002'})" >/dev/null 2>&1
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/$GB"
ST=$(curl -sS -o /tmp/qa-cv.json -w "%{http_code}" "$BASE/qa/gadgets-full/$GB")
HASMIRROR=$(jget '"upstreamMirror" in d["data"] and d["data"]["upstreamMirror"] is not None' /tmp/qa-cv.json)
{ [ "$ST" = "200" ] && [ "$HASMIRROR" = "False" ]; } && ok "LEFT join: row served, mirror null/absent" || bad "LEFT semantics broken (status=$ST mirror=$HASMIRROR)"

##############################################################################
sec "6. Per-leg authorization overlay in ToCriteria (R9/D1)"
##############################################################################
title "6.1 The composed by-id NEVER shows kind=internal (overlay Notes.Kind=public)"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/$GB?includeArchived=true"
BTX=$(jget '",".join(n["text"] for n in d["data"]["notes"])' /tmp/qa-cv.json)
case "$BTX" in *x-internal*) bad "overlay leaked the internal note: '$BTX'";; *) ok "internal note absent from the composed read ('$BTX')";; esac

title "6.2 The leg's OWN view still shows it (overlays are per surface, not per view)"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadget-notes/?gadgetId=$GB&kind=internal"
KN=$(jget 'len(d["data"])' /tmp/qa-cv.json)
KT=$(jget 'd["data"][0]["text"]' /tmp/qa-cv.json)
{ [ "$KN" = "1" ] && [ "$KT" = "x-internal" ]; } && ok "internal note readable on /qa/gadget-notes" || bad "leg view read wrong (n=$KN text='$KT')"

##############################################################################
sec "7. Export + GraphQL over the same composed name"
##############################################################################
title "7.1 GET /qa/gadgets-full.csv renders the leg branches"
ST=$(curl -sS -o /tmp/qa-cv.csv -w "%{http_code}" "$BASE/qa/gadgets-full.csv?code=CV-001")
grep -q "a1" /tmp/qa-cv.csv && CSVNOTE=y || CSVNOTE=n
grep -q "CV-001" /tmp/qa-cv.csv && CSVROOT=y || CSVROOT=n
{ [ "$ST" = "200" ] && [ "$CSVNOTE" = y ] && [ "$CSVROOT" = y ]; } && ok "CSV carries root + note rows" || bad "CSV export wrong (status=$ST note=$CSVNOTE root=$CSVROOT)"
rm -f /tmp/qa-cv.csv

title "7.2 GraphQL gadgetsFull connection serves the composed read"
curl -sS -o /tmp/qa-cv.json -X POST "$BASE/graphql" -H "Content-Type: application/json" \
  --data '{"query":"{ gadgetsFull(first: 5) { edges { node { code upstreamMirror { code } notes { text } } } } }"}'
GQL=$(jget '",".join(e["node"]["code"] for e in d["data"]["gadgetsFull"]["edges"])' /tmp/qa-cv.json)
GQLM=$(jget 'd["data"]["gadgetsFull"]["edges"][0]["node"]["upstreamMirror"]["code"]' /tmp/qa-cv.json)
GQLN=$(jget '",".join(n["text"] for n in d["data"]["gadgetsFull"]["edges"][0]["node"]["notes"])' /tmp/qa-cv.json)
case "$GQL" in *CV-001*) ok "GraphQL lists the composed items ($GQL)";; *) bad "GraphQL wrong: '$GQL' $(cat /tmp/qa-cv.json)";; esac
[ "$GQLM" = "CV-001" ] && ok "GraphQL nested mirror resolves" || bad "GraphQL mirror wrong ('$GQLM')"
[ "$GQLN" = "a1,b2,c3" ] && ok "GraphQL notes window matches" || bad "GraphQL notes wrong ('$GQLN')"

##############################################################################
sec "8. Primary knobs flow through the composed name unchanged"
##############################################################################
title "8.1 ?search= runs the primary's text index; hits are still enriched"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?search=One"
COUNT=$(jget 'len(d["data"])' /tmp/qa-cv.json)
SC=$(jget 'd["data"][0]["code"]' /tmp/qa-cv.json)
SN=$(jget 'len(d["data"][0].get("notes") or [])' /tmp/qa-cv.json)
{ [ "$COUNT" = "1" ] && [ "$SC" = "CV-001" ]; } && ok "search selected the matching gadget" || bad "search wrong (count=$COUNT code='$SC')"
[ "$SN" = "3" ] && ok "search hits are enriched like any composed read" || bad "search hit not enriched ($SN notes)"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?search=Composed"
COUNT=$(jget 'len(d["data"])' /tmp/qa-cv.json)
[ "$COUNT" = "2" ] && ok "shared token matches both" || bad "search=Composed returned '$COUNT'"

title "8.2 The primary's MaxLimit ceiling guards the composed name (?limit=200 → 400)"
ST=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/qa/gadgets-full/?limit=200")
[ "$ST" = "400" ] && ok "limit above the primary ceiling rejected" || bad "limit=200 returned $ST"

title "8.3 An empty result set is a clean page (no legs, no error)"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?code=NOPE"
ST=$(curl -sS -o /tmp/qa-cv.json -w "%{http_code}" "$BASE/qa/gadgets-full/?code=NOPE")
COUNT=$(jget 'len(d["data"]) if "data" in d else 0' /tmp/qa-cv.json)
TOTAL=$(jget 'd["pagination"]["total"]' /tmp/qa-cv.json)
{ [ "$ST" = "200" ] && [ "$COUNT" = "0" ] && [ "$TOTAL" = "0" ]; } && ok "empty page served cleanly" || bad "empty page wrong (st=$ST count=$COUNT total=$TOTAL)"

title "8.4 Backward navigation (?before=) round-trips on the composed name"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?sort=code&limit=1"
P1=$(jget 'd["data"][0]["code"]' /tmp/qa-cv.json)
NC=$(jget 'd["pagination"]["next_cursor"]' /tmp/qa-cv.json)
ENC=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$NC")
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?sort=code&limit=1&after=$ENC"
P2=$(jget 'd["data"][0]["code"]' /tmp/qa-cv.json)
PC=$(jget 'd["pagination"]["prev_cursor"]' /tmp/qa-cv.json)
ENCP=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$PC")
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?sort=code&limit=1&before=$ENCP"
PB=$(jget 'd["data"][0]["code"]' /tmp/qa-cv.json)
{ [ "$P1" = "CV-001" ] && [ "$P2" = "CV-002" ] && [ "$PB" = "CV-001" ]; } && ok "forward + backward keyset navigation ($P1 → $P2 → $PB)" || bad "cursor navigation wrong ($P1 → $P2 → $PB)"

##############################################################################
sec "9. Segment shaping extras — 1:1 filter, AND-ed operators, mirror fields"
##############################################################################
title "9.1 A 1:1 segment filter nulls the sub-document, never the row"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?upstreamMirror.code=ZZZ&sort=code"
COUNT=$(jget 'len(d["data"])' /tmp/qa-cv.json)
HASM=$(jget '"upstreamMirror" in d["data"][0] and d["data"][0]["upstreamMirror"] is not None' /tmp/qa-cv.json)
{ [ "$COUNT" = "2" ] && [ "$HASM" = "False" ]; } && ok "unmatched 1:1 filter → mirror null, rows intact" || bad "1:1 segment filter wrong (count=$COUNT mirror=$HASM)"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?upstreamMirror.code=CV-001&sort=code"
MC=$(jget 'd["data"][0]["upstreamMirror"]["code"]' /tmp/qa-cv.json)
[ "$MC" = "CV-001" ] && ok "matched 1:1 filter keeps the sub-document" || bad "matched 1:1 filter lost the mirror ('$MC')"

title "9.2 Multiple operators on one segment field AND-combine"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?notes.text.contains=1&notes.text=a1&sort=code"
ATX=$(jget '",".join(n["text"] for n in d["data"][0]["notes"])' /tmp/qa-cv.json)
[ "$ATX" = "a1" ] && ok "contains=1 AND eq=a1 → [a1]" || bad "AND-ed segment operators wrong: '$ATX'"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?notes.text.contains=1&notes.text=b2&sort=code"
AN=$(jget 'len(d["data"][0].get("notes") or [])' /tmp/qa-cv.json)
[ "$AN" = "0" ] && ok "unsatisfiable AND empties the segment" || bad "AND-ed operators leaked: $AN notes"

title "9.3 ?notes.kind=internal on the LIST — visible here, overlay-hidden on by-id"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?notes.kind=internal&sort=code"
AN=$(jget 'len(d["data"][0].get("notes") or [])' /tmp/qa-cv.json)
BTX=$(jget '",".join(n["text"] for n in d["data"][1]["notes"])' /tmp/qa-cv.json)
{ [ "$AN" = "0" ] && [ "$BTX" = "x-internal" ]; } && ok "the list (no overlay) can surface internal notes — the by-id contrast is the R9 proof" || bad "kind filter wrong (A=$AN B='$BTX')"

title "9.4 ?fields= projects into the 1:1 segment"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?fields=code,upstreamMirror.code&code=CV-001"
ITEM=$(jget 'sorted(d["data"][0].keys())' /tmp/qa-cv.json)
MK=$(jget 'sorted(d["data"][0]["upstreamMirror"].keys())' /tmp/qa-cv.json)
[ "$ITEM" = "['code', 'upstreamMirror']" ] && ok "item carries only code + mirror" || bad "unexpected item keys: $ITEM"
[ "$MK" = "['code']" ] && ok "mirror entry carries only code" || bad "unexpected mirror keys: $MK"

##############################################################################
sec "10. Archived PRIMARY through the composed name"
##############################################################################
title "10.1 Archive gadget B → composed by-id 404s on default reads"
curl -sS -o /dev/null -X PATCH "$BASE/qa/gadgets/$GB/archive"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); parch=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  ST=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/qa/gadgets-full/$GB")
  [ "$ST" = "404" ] && { parch=ok; break; }
  sleep 1
done
[ "$parch" = ok ] && ok "archived primary hidden (404)" || bad "archived primary still served ($ST)"

title "10.2 ?includeArchived=true serves it, legs attached (overlay still active)"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/$GB?includeArchived=true"
ST=$(curl -sS -o /tmp/qa-cv.json -w "%{http_code}" "$BASE/qa/gadgets-full/$GB?includeArchived=true")
BTX=$(jget '",".join(n["text"] for n in d["data"]["notes"])' /tmp/qa-cv.json)
{ [ "$ST" = "200" ] && [ "$BTX" = "b-pub" ]; } && ok "archived primary readable with legs (notes=[b-pub]: archived note lifted, internal overlay-hidden)" || bad "archived by-id wrong (st=$ST notes='$BTX')"

title "10.3 Default list drops the archived primary; unarchive restores it"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/"
COUNT=$(jget 'len(d["data"])' /tmp/qa-cv.json)
[ "$COUNT" = "1" ] && ok "default list shows only the active gadget" || bad "default list wrong ($COUNT)"
curl -sS -o /dev/null -X PATCH "$BASE/qa/gadgets/$GB/unarchive"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); prest=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/"
  COUNT=$(jget 'len(d["data"])' /tmp/qa-cv.json)
  [ "$COUNT" = "2" ] && { prest=ok; break; }
  sleep 1
done
[ "$prest" = ok ] && ok "unarchive restored the composed listing" || bad "unarchive never restored the listing"

##############################################################################
sec "11. Export extras — CSV field pruning + XLSX"
##############################################################################
title "11.1 CSV with ?fields=code,notes.text prunes root + segment columns"
ST=$(curl -sS -o /tmp/qa-cv.csv -w "%{http_code}" "$BASE/qa/gadgets-full.csv?fields=code,notes.text&code=CV-001")
grep -q "a1" /tmp/qa-cv.csv && HASNOTE=y || HASNOTE=n
grep -q "tools" /tmp/qa-cv.csv && HASCAT=y || HASCAT=n
{ [ "$ST" = "200" ] && [ "$HASNOTE" = y ] && [ "$HASCAT" = n ]; } && ok "pruned CSV keeps requested columns, drops the rest" || bad "CSV pruning wrong (st=$ST note=$HASNOTE category-leak=$HASCAT)"
rm -f /tmp/qa-cv.csv

title "11.2 XLSX export responds with a real workbook"
ST=$(curl -sS -o /tmp/qa-cv.xlsx -w "%{http_code}" "$BASE/qa/gadgets-full.xlsx?code=CV-001")
MAGIC=$(head -c 2 /tmp/qa-cv.xlsx 2>/dev/null)
SIZE=$(wc -c < /tmp/qa-cv.xlsx 2>/dev/null | tr -d ' ')
{ [ "$ST" = "200" ] && [ "$MAGIC" = "PK" ] && [ "${SIZE:-0}" -gt 1000 ]; } && ok "XLSX served (zip magic, ${SIZE}B)" || bad "XLSX wrong (st=$ST magic='$MAGIC' size=$SIZE)"
rm -f /tmp/qa-cv.xlsx

##############################################################################
sec "12. GraphQL extras — where + cursor navigation on the composed name"
##############################################################################
title "12.1 where folds like REST row filters"
curl -sS -o /tmp/qa-cv.json -X POST "$BASE/graphql" -H "Content-Type: application/json" \
  --data '{"query":"{ gadgetsFull(where: { code: { eq: \"CV-001\" } }, first: 5) { edges { node { code } } } }"}'
GN=$(jget 'len(d["data"]["gadgetsFull"]["edges"])' /tmp/qa-cv.json)
GC=$(jget 'd["data"]["gadgetsFull"]["edges"][0]["node"]["code"]' /tmp/qa-cv.json)
{ [ "$GN" = "1" ] && [ "$GC" = "CV-001" ]; } && ok "GraphQL where selects rows" || bad "GraphQL where wrong (n=$GN code='$GC')"

title "12.2 Relay cursor navigation over the composed connection"
curl -sS -o /tmp/qa-cv.json -X POST "$BASE/graphql" -H "Content-Type: application/json" \
  --data '{"query":"{ gadgetsFull(first: 1) { edges { node { code } cursor } } }"}'
GC1=$(jget 'd["data"]["gadgetsFull"]["edges"][0]["node"]["code"]' /tmp/qa-cv.json)
GCUR=$(jget 'd["data"]["gadgetsFull"]["edges"][0]["cursor"]' /tmp/qa-cv.json)
curl -sS -o /tmp/qa-cv.json -X POST "$BASE/graphql" -H "Content-Type: application/json" \
  --data "{\"query\":\"{ gadgetsFull(first: 1, after: \\\"$GCUR\\\") { edges { node { code notes { text } } } } }\"}"
GC2=$(jget 'd["data"]["gadgetsFull"]["edges"][0]["node"]["code"]' /tmp/qa-cv.json)
{ [ -n "$GCUR" ] && [ "$GC1" != "$GC2" ] && [ -n "$GC2" ]; } && ok "Relay after-cursor advanced ($GC1 → $GC2)" || bad "GraphQL cursor navigation wrong ($GC1 → '$GC2')"

##############################################################################
sec "13. Security overlay in ToCriteria × cursor pagination (framework fix)"
##############################################################################
# FindGadgetsFullQuery.ToCriteria overlays Status=active — the same seam a
# tenant gate uses. Before the framework fix, ANY ToCriteria filter overlay on
# a paged query broke navigation (the wire layer pre-compared the cursor hash
# against the PRE-overlay criteria → every ?after was 400). Now the hash check
# is authoritative at the reader, post-ToCriteria. Note: every cursor case
# above already ran WITH this overlay active; this section asserts the overlay
# is real (filters rows) AND that navigation survives it.
title "13.1 Seed a non-active gadget (status=retired)"
GC=$(curl -sS -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" \
  --data '{"code":"CV-003","name":"Composed Three","category":"tools","status":"retired"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null)
[ -n "$GC" ] && ok "retired gadget created ($GC)" || bad "retired gadget creation failed"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); seeded=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  g=$(mongoq "db.gadgets.countDocuments({})")
  [ "${g:-0}" = "3" ] && { seeded=ok; break; }
  sleep 1
done
[ "$seeded" = ok ] && ok "gadgets view carries 3 docs" || bad "CDC never landed the 3rd gadget"

title "13.2 The overlay filters rows: raw view shows 3, composed surface shows 2"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets/"
RAW=$(jget 'd["pagination"]["total"]' /tmp/qa-cv.json)
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?sort=code"
FULL=$(jget 'd["pagination"]["total"]' /tmp/qa-cv.json)
CODES=$(jget '",".join(i["code"] for i in d["data"])' /tmp/qa-cv.json)
{ [ "$RAW" = "3" ] && [ "$FULL" = "2" ]; } && ok "overlay hides the retired gadget from the composed surface (raw=3, composed=2)" || bad "overlay row gate wrong (raw=$RAW composed=$FULL)"
case "$CODES" in *CV-003*) bad "retired gadget leaked into the composed list ($CODES)";; *) ok "composed list carries only active gadgets ($CODES)";; esac

title "13.3 The composed by-id honors the same overlay (404 for the retired gadget)"
ST=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/qa/gadgets-full/$GC")
[ "$ST" = "404" ] && ok "retired gadget 404s on the composed by-id" || bad "composed by-id served a non-active gadget ($ST)"

title "13.4 Cursor navigation round-trips WITH the security overlay (the fixed bug)"
curl -sS -o /tmp/qa-cv.json "$BASE/qa/gadgets-full/?sort=code&limit=1"
P1=$(jget 'd["data"][0]["code"]' /tmp/qa-cv.json)
NC=$(jget 'd["pagination"]["next_cursor"]' /tmp/qa-cv.json)
ENC=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$NC")
ST=$(curl -sS -o /tmp/qa-cv.json -w "%{http_code}" "$BASE/qa/gadgets-full/?sort=code&limit=1&after=$ENC")
P2=$(jget 'd["data"][0]["code"]' /tmp/qa-cv.json)
{ [ "$ST" = "200" ] && [ "$P1" = "CV-001" ] && [ "$P2" = "CV-002" ]; } && ok "?after accepted with the ToCriteria overlay active ($P1 → $P2)" || bad "overlay broke pagination (st=$ST $P1 → '$P2')"

##############################################################################
sec "Cleanup + Summary"
##############################################################################
qa_db_exec "DELETE FROM gadget_notes;" 2>/dev/null || true
qa_db_exec "DELETE FROM gadgets;" 2>/dev/null || true
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
