#!/usr/bin/env bash
# Aggregates suite — the write-path aggregate DSL end to end, through the
# qa-only Product fixture (`//go:build qa`): scalar facts computed on the
# RELATIONAL side by the AggregateLoader, never a Mongo view.
#
#   GET  /qa/products/stats  → ONE Aggregate SELECT (ungrouped: Count/SumInt/
#                              MinInt/MaxInt + Avg/Sum/Min/Max) + ONE
#                              AggregateBy SELECT (the same specs per
#                              GROUP BY category, ordered by key ascending)
#   POST /qa/products        → BuildRules consumes the grouped facts through a
#                              domain.Service (ProductStats port): an insert
#                              creating a FOURTH distinct active category is
#                              rejected (422 LimitExceededNotification)
#
# The money doctrine rides the whole suite: priceCents is int64 minor units and
# every sum/extreme must come back EXACT on both engines (pg NUMERIC via
# pgtype.Numeric, MySQL DECIMAL as text). Archive/unarchive prove the
# active-only scope gate folds rows out of (and back into) the grouped facts,
# and ?includeArchived=true widens the same criteria the DSL compiled.
#
# Self-managed; qa binary (-tags '<engine> qa') + microservice.qa.yaml.
# Dialect-driven via qa/_backend.sh.  Run from anywhere:  bash qa/aggregates.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-aggregates-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-aggregates-${BACKEND:-postgres}.log"

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
  # A qa-binary boot registers the gadget Mongo views; drop them so a later
  # non-qa prd suite (audit/authz) does not abort on foreign collections.
  docker exec omnicore-qa-mongo mongosh "$QA_MONGO_DB" --quiet --eval 'db.gadgets.drop(); db.gadget_notes.drop(); db.gadgets_hot.drop(); db.gadgets_capped.drop(); db.upstream_gadgets.drop()' >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# stats_summary [includeArchived] → one canonical line:
#   <global row>|T/F@<cat>:<row>;<cat>:<row>...
# where a row is count:sumCents:minCents:maxCents:avgWeight:sumWeight:minWeight:maxWeight.
# Floats render via python format(x,'g') (6 significant digits), which absorbs
# cross-engine floating-point noise while keeping the exact-money integers raw.
stats_summary() {
  local qs=""
  [ "${1:-}" = "archived" ] && qs="?includeArchived=true"
  curl -sS "$BASE/qa/products/stats$qs" | python3 -c '
import sys, json
d = json.load(sys.stdin)["data"]
def f(x): return format(x, "g")
def row(s):
    return ":".join([str(s["count"]), str(s["sumCents"]), str(s["minCents"]), str(s["maxCents"]),
                     f(s["avgWeight"]), f(s["sumWeight"]), f(s["minWeight"]), f(s["maxWeight"])])
g = d["global"]
cats = ";".join(c["category"] + ":" + row(c) for c in d["categories"])
print(row(g) + ("|T" if g["found"] else "|F") + "@" + cats)
'
}

# post_product <code> <category> <priceCents> <weight> → echoes "<status> <id>"
post_product() {
  local resp status id
  resp=$(curl -sS -w '\n%{http_code}' -X POST "$BASE/qa/products" -H "Content-Type: application/json" \
    --data "{\"code\":\"$1\",\"category\":\"$2\",\"priceCents\":$3,\"weight\":$4}")
  status=$(echo "$resp" | tail -n1)
  id=$(echo "$resp" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null)
  echo "$status $id"
}

##############################################################################
sec "0. Build qa binary + boot + reset product state"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"

title "0.2 Start server (APP_PROFILE=dev, config=microservice.qa.yaml)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$REPO_ROOT/microservice.qa.yaml" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready (PID=$SERVER_PID)" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }

title "0.3 Reset qa_products (SQL)"
qa_db_exec "DELETE FROM qa_products;"
ok "clean product baseline"

title "0.4 Empty set: Count 0, found=false, ZERO groups"
S=$(stats_summary)
E="0:0:0:0:0:0:0:0|F@"
[ "$S" = "$E" ] && ok "empty stats ($S)" || bad "empty stats: got '$S' want '$E'"

##############################################################################
sec "1. Ungrouped + grouped facts over a seeded set (exact money arithmetic)"
##############################################################################
title "1.1 Seed books x2 + tools x1"
for spec in "AGG-B1 books 1050 1.5" "AGG-B2 books 120 2.25" "AGG-T1 tools 500 3.0"; do
  set -- $spec
  R=$(post_product "$1" "$2" "$3" "$4"); ST=${R%% *}
  [ "$ST" = "201" ] && ok "insert $1 ($2)" || bad "insert $1 status $ST"
  [ "$1" = "AGG-B1" ] && PID_B1=${R#* }
done

title "1.2 Global facts — ONE SELECT, exact minor units"
S=$(stats_summary)
E="3:1670:120:1050:2.25:6.75:1.5:3|T@books:2:1170:120:1050:1.875:3.75:1.5:2.25;tools:1:500:500:500:3:3:3:3"
[ "$S" = "$E" ] && ok "stats match (global + per-category, ordered by key)" || bad "stats: got '$S' want '$E'"

##############################################################################
sec "2. The grouped-facts rule: max 3 DISTINCT active categories"
##############################################################################
title "2.1 Third category (garden) → 201"
R=$(post_product "AGG-G1" "garden" 700 1.2); ST=${R%% *}; PID_G1=${R#* }
[ "$ST" = "201" ] && ok "garden accepted (3rd distinct category)" || bad "garden status $ST"

title "2.2 Fourth category (auto) → 422 ProductCategoryLimitNotification"
RESP=$(curl -sS -w '\n%{http_code}' -X POST "$BASE/qa/products" -H "Content-Type: application/json" \
  --data '{"code":"AGG-A1","category":"auto","priceCents":10,"weight":0.1}')
ST=$(echo "$RESP" | tail -n1); BODY=$(echo "$RESP" | sed '$d')
[ "$ST" = "422" ] && ok "fourth category rejected (422)" || bad "fourth category status $ST (want 422)"
echo "$BODY" | grep -q '"notificationKey":"ProductCategoryLimitNotification"' \
  && ok "envelope carries ProductCategoryLimitNotification" || bad "envelope missing ProductCategoryLimitNotification: $BODY"

title "2.3 Existing category at the limit (books) → 201"
R=$(post_product "AGG-B3" "books" 30 0.75); ST=${R%% *}
[ "$ST" = "201" ] && ok "existing category always passes" || bad "books-at-limit status $ST"

title "2.4 Facts after the rule round"
S=$(stats_summary)
E="5:2400:30:1050:1.74:8.7:0.75:3|T@books:3:1200:30:1050:1.5:4.5:0.75:2.25;garden:1:700:700:700:1.2:1.2:1.2:1.2;tools:1:500:500:500:3:3:3:3"
[ "$S" = "$E" ] && ok "stats match after inserts" || bad "stats: got '$S' want '$E'"

##############################################################################
sec "3. The scope gate rides the grouped SELECT (archive / includeArchived)"
##############################################################################
title "3.1 Archive AGG-B1 (1050 cents) → folds out of the active facts"
ST=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH "$BASE/qa/products/$PID_B1/archive")
[ "$ST" = "200" ] && ok "archive 200" || bad "archive status $ST"
S=$(stats_summary)
E="4:1350:30:700:1.8:7.2:0.75:3|T@books:2:150:30:120:1.5:3:0.75:2.25;garden:1:700:700:700:1.2:1.2:1.2:1.2;tools:1:500:500:500:3:3:3:3"
[ "$S" = "$E" ] && ok "active facts exclude the archived row (MAX fell 1050→700)" || bad "stats: got '$S' want '$E'"

title "3.2 ?includeArchived=true widens the same criteria"
S=$(stats_summary archived)
E="5:2400:30:1050:1.74:8.7:0.75:3|T@books:3:1200:30:1050:1.5:4.5:0.75:2.25;garden:1:700:700:700:1.2:1.2:1.2:1.2;tools:1:500:500:500:3:3:3:3"
[ "$S" = "$E" ] && ok "archived row folds back in under the widened scope" || bad "stats: got '$S' want '$E'"

##############################################################################
sec "4. The rule reads ACTIVE facts: archiving a whole category frees a slot"
##############################################################################
title "4.1 Archive AGG-G1 → the garden group VANISHES (zero rows, zero group)"
ST=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH "$BASE/qa/products/$PID_G1/archive")
[ "$ST" = "200" ] && ok "archive 200" || bad "archive status $ST"
CATS=$(stats_summary | sed 's/.*@//')
case "$CATS" in books:*\;tools:*) ok "garden group gone (categories: books,tools)";; *) bad "categories after archive: '$CATS'";; esac

title "4.2 A new category (neon) now fits → 201"
R=$(post_product "AGG-N1" "neon" 900 0.5); ST=${R%% *}
[ "$ST" = "201" ] && ok "neon accepted (slot freed by the archive)" || bad "neon status $ST"

title "4.3 And the next new one (cyber) hits the cap again → 422"
ST=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE/qa/products" -H "Content-Type: application/json" \
  --data '{"code":"AGG-C1","category":"cyber","priceCents":10,"weight":0.1}')
[ "$ST" = "422" ] && ok "cyber rejected (books,neon,tools = 3 active categories)" || bad "cyber status $ST (want 422)"

##############################################################################
sec "5. Unarchive folds the group back in (deterministic key order)"
##############################################################################
title "5.1 Unarchive AGG-G1 → 4 active categories, ordered ascending"
ST=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH "$BASE/qa/products/$PID_G1/unarchive")
[ "$ST" = "200" ] && ok "unarchive 200" || bad "unarchive status $ST"
NAMES=$(curl -sS "$BASE/qa/products/stats" | python3 -c 'import sys,json;print(",".join(c["category"] for c in json.load(sys.stdin)["data"]["categories"]))')
[ "$NAMES" = "books,garden,neon,tools" ] && ok "groups ordered by key ascending ($NAMES)" || bad "group order: '$NAMES'"

title "5.2 Inserts into NEW categories stay capped (omega → 422)"
ST=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE/qa/products" -H "Content-Type: application/json" \
  --data '{"code":"AGG-O1","category":"omega","priceCents":10,"weight":0.1}')
[ "$ST" = "422" ] && ok "omega rejected (4 active categories ≥ cap)" || bad "omega status $ST (want 422)"

##############################################################################
sec "6. Cleanup"
##############################################################################
qa_db_exec "DELETE FROM qa_products;"
ok "qa_products cleared"

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
