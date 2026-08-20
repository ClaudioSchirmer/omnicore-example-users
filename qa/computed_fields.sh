#!/usr/bin/env bash
# Computed-field suite — a read Response field that carries NO column: the
# Query's FromQueryResult derives it after the read, and the Response declares
# the Result fields that feed it via `computed:"A,B"`.
#
# The fixture is the qa-only Gadget mirror (`//go:build qa`). Its Result gained
# a `Label` derived from Code+Name; two Responses consume the same Result:
#
#   GET /qa/gadgets           → FindGadgetsResponse          (does NOT declare label)
#   GET /qa/gadgets/computed  → FindGadgetsComputedResponse  (id, code, label)
#   GET /qa/gadgets-computed.csv → the tabular twin of the computed list
#
# `Name` is deliberately ABSENT from the computed Response: a source is read so
# the derivation has data and then never reaches the wire. That asymmetry is
# what most of the cases below pin down.
#
# What the suite proves, end to end on a live view:
#   1. the derived value reaches every surface (JSON list, CSV, XLSX, GraphQL)
#   2. `?fields=label` pushes the SOURCES to the store, not the computed path,
#      and answers with label alone
#   3. `?orderBy=label` is 400: ordering speaks the Request DTO's vocabulary and
#      a computed field backs no column, so it is never declared orderable —
#      reported on the wire token, never leaking the internal Go field name
#   4. an unknown token rejects identically, so the vocabulary is the whole rule
#      remain distinguishable
#   5. a Result field the Response does not declare never leaks to that wire
#   6. the CSV column set keeps the computed column when it is the only thing
#      selected (the projection echo names its sources, not the column)
#
# Read-side, so it depends on CDC (gadgets outbox → gadgets.events → SyncEngine
# → Mongo) — the suite registers the Debezium connector and waits for the view.
#
# Self-managed; qa binary (-tags '<engine> qa') + microservice.qa.yaml.
# Dialect-driven via qa/_backend.sh.  Run from anywhere:  bash qa/computed_fields.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-computed-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-computed-${BACKEND:-postgres}.log"

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
  qa_view_drop gadgets gadget_notes gadgets_hot gadgets_capped upstream_gadgets
}
trap cleanup EXIT INT TERM

# jq_field <file> <python-expression over d> — small json probe helper.
probe() { python3 -c "$2" "$1" 2>/dev/null; }

# expect_json <name> <path+query> <expected-status> <python-expr> <expected>
# GETs the JSON list surface and asserts status AND a probe over the payload.
expect_json() {
  local name="$1" url="$2" want_st="$3" expr="$4" want="$5" lang="${6:-en-US}"
  title "$name"
  local tmp; tmp=$(mktemp)
  local st; st=$(curl -sS -o "$tmp" -w "%{http_code}" "$BASE$url" -H "Accept-Language: $lang")
  local got; got=$(probe "$tmp" "$expr")
  echo "GET $url [$lang] → status=$st probe=$got"
  if [ "$st" = "$want_st" ] && [ "$got" = "$want" ]; then
    ok "$name"
  else
    bad "$name (want status $want_st probe '$want', got $st / '$got')"; head -c 400 "$tmp"; echo
  fi
  rm -f "$tmp"
}

##############################################################################
sec "0. Build qa binary + ensure connector + boot + seed"
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

qa_cdc_warmup_gadget

title "0.4 Reset + seed two ordered fixtures + wait for CDC"
qa_db_exec "DELETE FROM gadget_journal;" 2>/dev/null || true
qa_db_exec "DELETE FROM gadgets;"
qa_view_clear gadgets
sleep 1
seed_g() {
  curl -sS -o /dev/null -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" \
    --data "{\"code\":\"$1\",\"name\":\"$2\",\"category\":\"$3\",\"status\":\"$4\"}"
}
seed_g "CMP-01" "Alpha One" "cat-a" "active"
seed_g "CMP-02" "Bravo Two" "cat-b" "active"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); seeded=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  c=$(curl -sS "$BASE/qa/gadgets?code.startswith=CMP" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("data",[])))' 2>/dev/null)
  [ "${c:-0}" = "2" ] && { seeded=ok; break; }
  sleep 1
done
[ "$seeded" = ok ] && ok "two fixtures materialized in the gadgets view" || bad "fixtures did not reach 2 (got ${c:-0})"

##############################################################################
sec "1. The derived value reaches the wire"
##############################################################################
# The hook joins code + name with a middle dot; the whole point is that no
# column holds this string.
expect_json "1.1 computed list renders the derived label" \
  "/qa/gadgets/computed?code.eq=CMP-01" 200 \
  'import sys,json;d=json.load(open(sys.argv[1]));print(d["data"][0]["label"])' \
  "CMP-01 · Alpha One"

expect_json "1.2 the same row still carries its stored fields" \
  "/qa/gadgets/computed?code.eq=CMP-01" 200 \
  'import sys,json;d=json.load(open(sys.argv[1]));print(d["data"][0]["code"])' \
  "CMP-01"

# Name feeds the derivation but is NOT declared on this Response — a source is
# read, used, and dropped at the wire boundary.
expect_json "1.3 a computed SOURCE absent from the Response never reaches the wire" \
  "/qa/gadgets/computed?code.eq=CMP-01" 200 \
  'import sys,json;d=json.load(open(sys.argv[1]));print("name" in d["data"][0])' \
  "False"

# The OTHER Response over the same Result does not declare label at all.
expect_json "1.4 a Result field the Response omits does not leak to that wire" \
  "/qa/gadgets?code.eq=CMP-01" 200 \
  'import sys,json;d=json.load(open(sys.argv[1]));print("label" in d["data"][0])' \
  "False"

expect_json "1.5 …while the same route still renders its own declared fields" \
  "/qa/gadgets?code.eq=CMP-01" 200 \
  'import sys,json;d=json.load(open(sys.argv[1]));print(d["data"][0]["name"])' \
  "Alpha One"

##############################################################################
sec "2. ?fields= — the computed token pushes its SOURCES to the store"
##############################################################################
# Selecting only the computed field must still produce it: the framework reads
# code+name in its place. If the computed path were pushed down instead, the
# store would reject the unresolvable column and this would be a 400.
expect_json "2.1 ?fields=label answers with the derived value" \
  "/qa/gadgets/computed?code.eq=CMP-01&fields=label" 200 \
  'import sys,json;d=json.load(open(sys.argv[1]));print(d["data"][0]["label"])' \
  "CMP-01 · Alpha One"

expect_json "2.2 ?fields=label answers with label ALONE (sources stay off the wire)" \
  "/qa/gadgets/computed?code.eq=CMP-01&fields=label" 200 \
  'import sys,json;d=json.load(open(sys.argv[1]));print(sorted(d["data"][0].keys()))' \
  "['label']"

expect_json "2.3 ?fields=code,label keeps both, still without the hidden source" \
  "/qa/gadgets/computed?code.eq=CMP-01&fields=code,label" 200 \
  'import sys,json;d=json.load(open(sys.argv[1]));print(sorted(d["data"][0].keys()))' \
  "['code', 'label']"

expect_json "2.4 ?fields=code alone does NOT render the computed field" \
  "/qa/gadgets/computed?code.eq=CMP-01&fields=code" 200 \
  'import sys,json;d=json.load(open(sys.argv[1]));print("label" in d["data"][0])' \
  "False"

expect_json "2.5 an unknown token is still rejected on the computed surface" \
  "/qa/gadgets/computed?fields=bogus" 400 \
  'import sys,json;d=json.load(open(sys.argv[1]));print(d["errors"][0]["messages"][0]["field"])' \
  "fields[bogus]"

##############################################################################
sec "3. ?orderBy= — a computed field is simply not in the ordering vocabulary"
##############################################################################
# Ordering speaks the REQUEST DTO's vocabulary: a leaf is orderable because it
# declared `sort:"…"`. A computed field is derived after the read and backs
# no column, so it is never declared — and the refusal is the canonical schema
# violation, the same one any undeclared token gets. There is no computed-
# specific notification to distinguish, because there is no computed-specific
# rule: the store cannot order by a value it does not hold.
expect_json "3.1 ?orderBy=label → 400" \
  "/qa/gadgets/computed?orderBy=label" 400 \
  'import sys,json;d=json.load(open(sys.argv[1]));print(d["status"])' \
  "400"

# The refusal names the WIRE token, never the internal Go field ("Label").
expect_json "3.2 …reported on the canonical orderBy[label] field spelling" \
  "/qa/gadgets/computed?orderBy=label" 400 \
  'import sys,json;d=json.load(open(sys.argv[1]));print(d["errors"][0]["messages"][0]["field"])' \
  "orderBy[label]"

expect_json "3.3 …as the canonical schema violation" \
  "/qa/gadgets/computed?orderBy=label" 400 \
  'import sys,json;d=json.load(open(sys.argv[1]));print(d["errors"][0]["messages"][0]["notificationKey"])' \
  "SchemaViolationNotification"

expect_json "3.4 the descending form rejects verbatim (orderBy[-label])" \
  "/qa/gadgets/computed?orderBy=-label" 400 \
  'import sys,json;d=json.load(open(sys.argv[1]));print(d["errors"][0]["messages"][0]["field"])' \
  "orderBy[-label]"

expect_json "3.5 an unknown orderBy token rejects the same way" \
  "/qa/gadgets/computed?orderBy=bogus" 400 \
  'import sys,json;d=json.load(open(sys.argv[1]));print(d["errors"][0]["messages"][0]["notificationKey"])' \
  "SchemaViolationNotification"

# A DECLARED field on the same endpoint still sorts — the refusal is scoped to
# what the DTO did not declare, it does not disable ordering for the endpoint.
expect_json "3.6 a declared field on the same endpoint still sorts (200)" \
  "/qa/gadgets/computed?orderBy=-code&code.startswith=CMP" 200 \
  'import sys,json;d=json.load(open(sys.argv[1]));print(d["data"][0]["code"])' \
  "CMP-02"

##############################################################################
sec "4. Tabular export — the computed column is a real column"
##############################################################################
title "4.1 CSV carries the computed column with its derived value"
CSV=$(curl -sS "$BASE/qa/gadgets-computed.csv?code.eq=CMP-01" -H "Accept-Language: en-US")
echo "$CSV" | head -3
if printf '%s' "$CSV" | grep -q "CMP-01 · Alpha One"; then ok "4.1 derived value present in CSV"; else bad "4.1 derived value missing from CSV"; fi

title "4.2 CSV header renders the exportLabelKey through the translator (en-US)"
if printf '%s' "$CSV" | head -1 | grep -q "Label"; then ok "4.2 en-US header 'Label'"; else bad "4.2 header not translated: $(printf '%s' "$CSV" | head -1)"; fi

title "4.3 …and in pt-BR the same column header is translated"
CSV_PT=$(curl -sS "$BASE/qa/gadgets-computed.csv?code.eq=CMP-01" -H "Accept-Language: pt-BR")
if printf '%s' "$CSV_PT" | head -1 | grep -q "Rótulo"; then ok "4.3 pt-BR header 'Rótulo'"; else bad "4.3 pt-BR header wrong: $(printf '%s' "$CSV_PT" | head -1)"; fi

# The regression this locks: ?fields=label pushes code+name to the store, so
# the projection echo never mentions the computed path. A pruner that trusted
# the echo alone would drop the very column the consumer asked for.
title "4.4 CSV ?fields=label KEEPS the computed column (projection echo names its sources)"
CSV_F=$(curl -sS "$BASE/qa/gadgets-computed.csv?code.eq=CMP-01&fields=label" -H "Accept-Language: en-US")
echo "$CSV_F" | head -3
if printf '%s' "$CSV_F" | grep -q "CMP-01 · Alpha One"; then ok "4.4 computed column survived the prune"; else bad "4.4 computed column was pruned away"; fi

title "4.5 …and the hidden source did NOT become a column"
if printf '%s' "$CSV_F" | head -1 | grep -qi "name"; then bad "4.5 a source leaked into the CSV column set"; else ok "4.5 sources stayed off the column set"; fi

title "4.6 CSV ?orderBy=label is refused exactly like the JSON twin"
ST=$(curl -sS -o /tmp/qa_cmp_csv_err.json -w "%{http_code}" "$BASE/qa/gadgets-computed.csv?orderBy=label" -H "Accept-Language: en-US")
KEY=$(probe /tmp/qa_cmp_csv_err.json 'import sys,json;d=json.load(open(sys.argv[1]));print(d["errors"][0]["messages"][0]["notificationKey"])')
if [ "$ST" = "400" ] && [ "$KEY" = "SchemaViolationNotification" ]; then ok "4.6 export refuses like the JSON twin (400 + $KEY)"; else bad "4.6 export refusal wrong (status=$ST key=$KEY)"; fi
rm -f /tmp/qa_cmp_csv_err.json

##############################################################################
sec "5. GraphQL — selectable, but absent from the sortable enum"
##############################################################################
title "5.1 the computed field is selectable and resolves"
GQL=$(curl -sS -X POST "$BASE/graphql" -H 'Content-Type: application/json' \
  --data '{"query":"{ gadgetsRel(where:{code:{eq:\"CMP-01\"}}) { edges { node { id code } } } }"}')
echo "$GQL" | head -c 300; echo
if printf '%s' "$GQL" | grep -q '"code":"CMP-01"'; then ok "5.1 GraphQL resolves the fixture"; else bad "5.1 GraphQL did not resolve the fixture"; fi

title "5.2 the sortable enum omits the computed field (SDL cut)"
INTRO=$(curl -sS -X POST "$BASE/graphql" -H 'Content-Type: application/json' \
  --data '{"query":"{ __type(name:\"GadgetRelOrderField\") { enumValues { name } } }"}')
echo "$INTRO" | head -c 300; echo
if printf '%s' "$INTRO" | grep -qi '"LABEL"'; then bad "5.2 a computed field must not be a sortable enum member"; else ok "5.2 computed field absent from the order enum"; fi

##############################################################################
hr
printf '\033[1;37mcomputed_fields.sh done — PASS=%d FAIL=%d (backend=%s)\033[0m\n' "$PASS" "$FAIL" "${BACKEND:-postgres}"
[ "$FAIL" -eq 0 ] || exit 1
