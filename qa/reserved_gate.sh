#!/usr/bin/env bash
# Reserved-gate suite — the "DTO governs every surface" posture, end to end.
#
# The Request DTO is the single source of truth for what a list endpoint
# exposes: every reserved control key (first/last/after/before/orderBy/fields/
# search/includeArchived/onlyTotal) is opt-in via a `query:"…"` declaration,
# and EVERY surface obeys that cut through ONE canonical validation gateway
# (queryschema.ValidateControls), each rendering the rejection in its own
# idiom:
#
#   REST     → 400 SchemaViolation, field = the control key
#   GraphQL  → the SDL cut: undeclared args are absent from the schema, so
#              gqlparser rejects them as unknown arguments before any
#              resolver runs (introspection/playground never advertise them)
#   gRPC     → INVALID_ARGUMENT (the shared proto shows every field; the DTO
#              decides what THIS endpoint honors — runtime rejection)
#
# Proof surfaces (qa fixtures): GET /qa/gadgets/bare + GraphQL `gadgetsBare`
# + QAService.ListGadgetsBare — same view/handler as the declared gadgets
# list, but a Request DTO with ONLY filter leaves. The declared surface
# (/qa/gadgets, `gadgetsRel`, ListGadgets) proves the pass-through side plus
# the directional rule (forward first/after × backward last/before) and the
# only-total conflict matrix.
#
# No CDC dependency: every case is a pre-handler rejection or an empty read.
# Self-managed; qa binary (-tags '<engine> qa') + microservice.qa.yaml.
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-reserved-gate-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-reserved-gate-${BACKEND:-postgres}.log"

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
}
trap cleanup EXIT INT TERM

# rest_reject <name> <path> <query-string> <want-field> — 400 + the canonical
# per-field triple naming the control key.
rest_reject() {
  local name="$1" path="$2" qs="$3" want="$4"
  title "$name"
  local tmp; tmp=$(mktemp)
  local st; st=$(curl -sS -o "$tmp" -w "%{http_code}" "$BASE$path?$qs")
  local field; field=$(python3 -c 'import sys,json
try:
  d=json.load(open(sys.argv[1]))
  print(d["errors"][0]["messages"][0]["field"])
except Exception: print("<none>")' "$tmp")
  if [ "$st" = "400" ] && [ "$field" = "$want" ]; then
    ok "$name (400 field=$field)"
  else
    bad "$name (want 400/$want, got $st/$field)"; head -c 300 "$tmp"; echo
  fi
  rm -f "$tmp"
}

rest_pass() { # rest_pass <name> <path> <query-string>
  local name="$1" path="$2" qs="$3"
  title "$name"
  local st
  if [ -n "$qs" ]; then st=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE$path?$qs")
  else st=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE$path"); fi
  [ "$st" = "200" ] && ok "$name (200)" || bad "$name (want 200, got $st)"
}

gql() { # gql <query> → body on stdout
  curl -sS -X POST "$BASE/graphql" -H "Content-Type: application/json" \
    --data "$(python3 -c 'import json,sys;print(json.dumps({"query":sys.argv[1]}))' "$1")"
}

##############################################################################
sec "0. Build qa binary + boot"
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

##############################################################################
sec "1. REST — the bare endpoint rejects every reserved control"
##############################################################################
rest_reject "1.1 ?first rejected (NotDeclared)"           "/qa/gadgets/bare" "first=5"              "first"
rest_reject "1.2 ?last rejected"                          "/qa/gadgets/bare" "last=5"               "last"
rest_reject "1.3 ?after rejected"                         "/qa/gadgets/bare" "after=cur"            "after"
rest_reject "1.4 ?before rejected"                        "/qa/gadgets/bare" "before=cur"           "before"
rest_reject "1.5 ?orderBy rejected"                       "/qa/gadgets/bare" "orderBy=-name"        "orderBy"
rest_reject "1.6 ?fields rejected"                        "/qa/gadgets/bare" "fields=name"          "fields"
rest_reject "1.7 ?search rejected"                        "/qa/gadgets/bare" "search=x"             "search"
rest_reject "1.8 ?includeArchived rejected"               "/qa/gadgets/bare" "includeArchived=true" "includeArchived"
rest_reject "1.9 ?onlyTotal rejected"                     "/qa/gadgets/bare" "onlyTotal=true"       "onlyTotal"
rest_pass   "1.10 filter leaf still works on the bare DTO" "/qa/gadgets/bare" "code.startswith=GADGET"
rest_pass   "1.11 clean list works on the bare DTO"        "/qa/gadgets/bare" ""

# The by-id surface obeys the same gate: its one reserved control
# (?includeArchived) rejects when the by-id DTO does not declare it, and a
# declared by-id keeps honoring the key (404 for a ghost id — NOT 400).
rest_reject "1.12 by-id ?includeArchived rejected on the bare by-id DTO" \
  "/qa/gadgets/bare/00000000-0000-0000-0000-000000000000" "includeArchived=true" "includeArchived"
title "1.13 declared by-id still honors ?includeArchived (ghost id → 404, not 400)"
ST=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/qa/gadgets/00000000-0000-0000-0000-000000000000?includeArchived=true")
[ "$ST" = "404" ] && ok "declared by-id accepts the key (404)" || bad "declared by-id want 404, got $ST"

##############################################################################
sec "2. REST — directional rule + only-total matrix on the declared endpoint"
##############################################################################
rest_reject "2.1 first+last → backward-side key"          "/qa/gadgets" "last=3&first=2"       "last"
rest_reject "2.2 first+before → before"                   "/qa/gadgets" "before=cur&first=2"   "before"
rest_reject "2.3 last+after → last"                       "/qa/gadgets" "after=cur&last=2"     "last"
rest_reject "2.4 after+before → before"                   "/qa/gadgets" "before=cur&after=cur" "before"
rest_reject "2.5 first=0 → non-positive size"             "/qa/gadgets" "first=0"              "first"
rest_reject "2.6 last=-1 → non-positive size"             "/qa/gadgets" "last=-1"              "last"
rest_reject "2.7 onlyTotal+first → onlyTotal[first]"      "/qa/gadgets" "onlyTotal=true&first=2" "onlyTotal[first]"
rest_reject "2.8 onlyTotal+orderBy → onlyTotal[orderBy]"  "/qa/gadgets" "onlyTotal=true&orderBy=-name" "onlyTotal[orderBy]"
rest_pass   "2.9 last alone is valid (backward window)"   "/qa/gadgets" "last=2"
rest_pass   "2.10 onlyTotal+filter still valid"           "/qa/gadgets" "onlyTotal=true&code.startswith=G"

##############################################################################
sec "2b. REST — the value grammar of the declared controls"
##############################################################################
# Declaring a control opts the KEY in; it does not make every spelling of the
# VALUE legal. The two booleans take exactly `true` or `false` — the spellings
# proto `bool` and GraphQL `Boolean` accept and nothing else — so one value
# means one thing on every surface. `?includeArchived=1` used to be false on a
# listing and true on a by-id read of the same entity.
rest_reject "2b.1 ?includeArchived=1 → 400"        "/qa/gadgets" "includeArchived=1"     "includeArchived"
rest_reject "2b.2 ?includeArchived=TRUE → 400"     "/qa/gadgets" "includeArchived=TRUE"  "includeArchived"
rest_reject "2b.3 ?includeArchived= (empty) → 400" "/qa/gadgets" "includeArchived="      "includeArchived"
rest_reject "2b.4 ?onlyTotal=1 → 400"              "/qa/gadgets" "onlyTotal=1"           "onlyTotal"
rest_reject "2b.5 ?onlyTotal= (empty) → 400"       "/qa/gadgets" "onlyTotal="            "onlyTotal"
rest_pass   "2b.6 ?includeArchived=false is a no-op, not a refusal" "/qa/gadgets" "includeArchived=false"
rest_pass   "2b.7 ?onlyTotal=false is a no-op, not a refusal"       "/qa/gadgets" "onlyTotal=false"

# The by-id route shares the DTO vocabulary, so it must share the grammar.
# PRESENCE is the key being on the wire: `?includeArchived=` is the control
# asked for with no answer, and both routes refuse it.
GHOST="/qa/gadgets/00000000-0000-0000-0000-000000000000"
rest_reject "2b.8 by-id ?includeArchived=1 → 400"        "$GHOST" "includeArchived=1" "includeArchived"
rest_reject "2b.9 by-id ?includeArchived= (empty) → 400" "$GHOST" "includeArchived="  "includeArchived"

# An ordering names each path at most once: the terms become the reader's sort
# document, where a duplicated key is malformed and the store refuses the whole
# read. The refusal names the SECOND occurrence — the token to remove — with
# the `-` prefix verbatim.
rest_reject "2b.10 ?orderBy=code,code → orderBy[code]"    "/qa/gadgets" "orderBy=code,code"   "orderBy[code]"
rest_reject "2b.11 ?orderBy=code,-code → orderBy[-code]"  "/qa/gadgets" "orderBy=code,-code"  "orderBy[-code]"
rest_pass   "2b.12 distinct paths in one ordering stay legal" "/qa/gadgets" "orderBy=code,-name"

##############################################################################
sec "2c. The ordering VOCABULARY — every consumer, one cut"
##############################################################################
# `query:"orderBy"` is the SWITCH: it decides whether the endpoint takes the
# parameter at all. `sort:` on a Request leaf is the VOCABULARY: which paths,
# in which directions. Six things consume that vocabulary and they must not
# drift — REST list, REST by-id, the CSV/XLSX export, the OpenAPI document,
# GraphQL and gRPC — over BOTH backings, since a Mongo view and its
# RelationalSource twin share the DTO.
#
# FindGadgetsRequest carries the three legal shapes of a query-tagged scalar:
#   code/name/category/status → filter: AND sort:"asc,desc"  (filterable + orderable)
#   createdAt                 → sort:"desc" ONLY             (VOCABULARY LEAF)
#   first/orderBy/…           → reserved controls
#
# `createdAt` is the interesting one: a MANAGED column FindGadgetsResponse does
# not render. Under the old Response-derived vocabulary it could not be ordered
# by at all — which is the whole reason the vocabulary moved to the Request.

REL="/qa/rel/gadgets"          # the RelationalSource twin of /qa/gadgets
CSV="/qa/gadgets-computed.csv" # the export sibling — its OWN criteria loop

# ── the vocabulary leaf carries no value on the wire ─────────────────────────
# It names an ordering path, it is not a filter key. Every REST consumer of the
# DTO refuses it as an undeclared key, on both backings.
rest_reject "2c.1  ?createdAt= is not a filter key (mongo)"      "/qa/gadgets" "createdAt=2020-01-01" "createdAt"
rest_reject "2c.2  …nor on the relational twin"                  "$REL"        "createdAt=2020-01-01" "createdAt"
rest_reject "2c.3  …nor on the export"                           "$CSV"        "createdAt=2020-01-01" "createdAt"

# ── it IS orderable, in the ONE direction it declared ────────────────────────
rest_pass   "2c.4  ?orderBy=-createdAt (mongo)"                  "/qa/gadgets" "orderBy=-createdAt"
rest_pass   "2c.5  ?orderBy=-createdAt (relational twin)"        "$REL"        "orderBy=-createdAt"
rest_pass   "2c.6  ?orderBy=-createdAt (export)"                 "$CSV"        "orderBy=-createdAt"
# Ordering by a column the RESPONSE does not render is the headline of the
# change: the Request declares it, so the store serves it.
rest_pass   "2c.7  …and the column is absent from the Response"  "/qa/gadgets" "orderBy=-createdAt&fields=code"

# ── the direction the declaration does NOT admit is refused like any token ───
rest_reject "2c.8  ?orderBy=createdAt (asc undeclared, mongo)"   "/qa/gadgets" "orderBy=createdAt" "orderBy[createdAt]"
rest_reject "2c.9  …same on the relational twin"                 "$REL"        "orderBy=createdAt" "orderBy[createdAt]"
rest_reject "2c.10 …same on the export"                          "$CSV"        "orderBy=createdAt" "orderBy[createdAt]"

# ── a path appears at most once (a duplicated sort key is malformed) ─────────
rest_reject "2c.11 ?orderBy=code,code → orderBy[code]"           "/qa/gadgets" "orderBy=code,code"  "orderBy[code]"
rest_reject "2c.12 ?orderBy=code,-code → orderBy[-code]"         "$REL"        "orderBy=code,-code" "orderBy[-code]"
rest_reject "2c.13 …on the export too"                           "$CSV"        "orderBy=code,code"  "orderBy[code]"

# ── an undeclared token, named verbatim with its prefix ──────────────────────
rest_reject "2c.14 ?orderBy=bogus"                               "/qa/gadgets" "orderBy=bogus"  "orderBy[bogus]"
rest_reject "2c.15 ?orderBy=-bogus keeps the prefix"             "/qa/gadgets" "orderBy=-bogus" "orderBy[-bogus]"

##############################################################################
sec "2d. OpenAPI — the document says exactly what the DTO declares"
##############################################################################
# The spec is a consumer of the vocabulary like any other: it must advertise
# what the endpoint accepts and NOTHING it would refuse.
title "2d.1 fetch /openapi.json"
SPEC=$(mktemp)
SPEC_ST=$(curl -sS -o "$SPEC" -w "%{http_code}" "$BASE/openapi.json")
[ "$SPEC_ST" = "200" ] && ok "openapi.json served" || { bad "openapi.json (status $SPEC_ST)"; }

# The spec key for a grouped route may or may not carry a trailing slash, so
# both helpers RESOLVE the path instead of assuming one — a wrong key would
# read as "no parameters" and pass the absence assertions for the wrong reason.
SPEC_PY='
import sys, json
d = json.load(open(sys.argv[1]))
paths = d.get("paths", {})
want = sys.argv[2]
key = next((k for k in (want, want + "/", want.rstrip("/")) if k in paths), None)
if key is None:
    print("__NO_SUCH_PATH__"); raise SystemExit(0)
op = paths[key].get("get", {}) or {}
params = [p for p in (op.get("parameters") or []) if p.get("in") == "query"]
if len(sys.argv) > 3:
    for p in params:
        if p.get("name") == sys.argv[3]:
            print(p.get("description", "")); break
else:
    for p in params:
        print(p.get("name", ""))
'
# param_names <path> → the query-parameter names of GET <path>, one per line
param_names() { python3 -c "$SPEC_PY" "$SPEC" "$1"; }
# param_desc <path> <name> → that parameter's description
param_desc() { python3 -c "$SPEC_PY" "$SPEC" "$1" "$2"; }

title "2d.1b the spec actually carries the endpoint (guards the assertions below)"
if param_names /qa/gadgets | grep -q '__NO_SUCH_PATH__'; then
  bad "the spec has no GET /qa/gadgets — every assertion below would pass vacuously"
else
  ok "GET /qa/gadgets present in the document"
fi

title "2d.2 the VOCABULARY LEAF is not advertised as a parameter"
if param_names /qa/gadgets | grep -qx "createdAt"; then
  bad "createdAt must NOT be a query parameter — the parser refuses it on every call"
else
  ok "createdAt absent from parameters[]"
fi

title "2d.3 …while the filter leaves and the control still are"
MISSING=""
for want in code name orderBy fields first; do
  param_names /qa/gadgets | grep -qx "$want" || MISSING="$MISSING $want"
done
[ -z "$MISSING" ] && ok "code/name/orderBy/fields/first advertised" || bad "missing parameters:$MISSING"

title "2d.4 the orderBy description enumerates the vocabulary WITH directions"
OB_DESC=$(param_desc /qa/gadgets orderBy)
echo "$OB_DESC" | grep -q 'createdAt' && echo "$OB_DESC" | grep -qi 'desc only' \
  && echo "$OB_DESC" | grep -q 'code' \
  && ok "orderBy description carries createdAt (desc only) + code" \
  || bad "orderBy description incomplete: $OB_DESC"

title "2d.5 the leaf's wire name appears ONLY there, never as a parameter"
# The relational twin shares the DTO, so it must say the same thing.
REL_DESC=$(param_desc "$REL" orderBy)
if param_names "$REL" | grep -qx "createdAt"; then
  bad "the relational twin advertises the vocabulary leaf as a parameter"
elif echo "$REL_DESC" | grep -q 'createdAt'; then
  ok "the relational twin's spec agrees with the mongo one"
else
  bad "the relational twin's orderBy description lost the vocabulary: $REL_DESC"
fi
rm -f "$SPEC"

##############################################################################
sec "3. GraphQL — the SDL cut (bare field) vs the declared field"
##############################################################################
title "3.1 gadgetsBare(first: 1) → unknown argument (cut at the schema)"
B=$(gql 'query { gadgetsBare(first: 1) { totalCount } }')
echo "$B" | grep -q '"errors"' && echo "$B" | grep -qi 'first' \
  && ok "undeclared arg rejected by validation" || { bad "expected unknown-argument error, got: $(echo "$B" | head -c 200)"; }

title "3.2 gadgetsBare(orderBy: [\"-name\"]) → unknown argument"
B=$(gql 'query { gadgetsBare(orderBy: ["-name"]) { totalCount } }')
echo "$B" | grep -q '"errors"' && echo "$B" | grep -qi 'orderBy' \
  && ok "undeclared orderBy rejected" || bad "expected unknown-argument error, got: $(echo "$B" | head -c 200)"

# The SDL cut is argument-by-argument (web/graphql/sdl.go emits one arg per
# DECLARED control), so proving it for `first` and `orderBy` proves nothing
# about the other five. SEVEN of the nine keys become GraphQL arguments; the
# loop below closes the gap for the remaining five.
#
# `fields` and `onlyTotal` are deliberately NOT in this list and their absence
# is not a hole: they are the two graphqlNaturalControls
# (web/graphql/criteria.go) — the selection set IS the projection, and a
# totalCount-only selection IS only-total — so neither is ever an argument to
# cut. 3.3 below pins that natural half.
gql_cut() { # gql_cut <name> <arg-expression> <arg-name>
  local name="$1" arg="$2" key="$3"
  title "$name"
  local B; B=$(gql "query { gadgetsBare(${arg}) { totalCount } }")
  echo "$B" | grep -q '"errors"' && echo "$B" | grep -qi "$key" \
    && ok "$name" || bad "$name (got: $(echo "$B" | head -c 200))"
}
gql_cut "3.2a gadgetsBare(last: 1) → unknown argument"                'last: 1'                  'last'
gql_cut "3.2b gadgetsBare(after: \"c\") → unknown argument"           'after: "c"'               'after'
gql_cut "3.2c gadgetsBare(before: \"c\") → unknown argument"          'before: "c"'              'before'
gql_cut "3.2d gadgetsBare(search: \"x\") → unknown argument"          'search: "x"'              'search'
gql_cut "3.2e gadgetsBare(includeArchived: true) → unknown argument"  'includeArchived: true'    'includeArchived'

title "3.3 gadgetsBare natural selections stay valid (totalCount + where)"
B=$(gql 'query { gadgetsBare(where: { code: { startswith: "G" } }) { totalCount } }')
echo "$B" | grep -q '"errors"' \
  && bad "where + totalCount must stay valid: $(echo "$B" | head -c 200)" || ok "where + only-total selection valid on the bare field"

title "3.4 declared field still advertises the args (first works)"
# Note the edges selection: totalCount-only + first would be the only-total
# conflict (the declared DTO opts into onlyTotal) — a correct rejection.
B=$(gql 'query { gadgetsRel(first: 1) { edges { node { id } } totalCount } }')
echo "$B" | grep -q '"errors"' \
  && bad "declared first must pass: $(echo "$B" | head -c 200)" || ok "declared field accepts first"

title "3.5 pagination probe: pageInfo without edges is valid"
B=$(gql 'query { gadgetsRel { pageInfo { hasNextPage hasPreviousPage } totalCount } }')
echo "$B" | grep -q '"errors"' \
  && bad "pageInfo probe must pass: $(echo "$B" | head -c 200)" || ok "pageInfo-only probe valid"

##############################################################################
sec "3b. GraphQL — the SAME vocabulary, this surface's spelling"
##############################################################################
# gadgetsRel serves FindGadgetsRequest over the RelationalSource twin, so this
# section proves the vocabulary AND the backing parity in one pass. The enum
# <Entity>OrderField is built from the sort: declarations, so introspection
# advertises exactly them; what an enum CANNOT express — per-member directions,
# and "at most once" — is cut in the resolver, as the same schema violation.

gql_reject_field() { # gql_reject_field <name> <query> <expected field marker>
  local name="$1" q="$2" want="$3"
  title "$name"
  local b; b=$(gql "$q")
  if echo "$b" | grep -q '"errors"' && echo "$b" | grep -qF "$want"; then
    ok "$name (field=$want)"
  else
    bad "$name (want an error naming $want, got: $(echo "$b" | head -c 250))"
  fi
}
gql_pass() { # gql_pass <name> <query>
  local name="$1" q="$2"
  title "$name"
  local b; b=$(gql "$q")
  echo "$b" | grep -q '"errors"' \
    && bad "$name (unexpected error: $(echo "$b" | head -c 250))" \
    || ok "$name"
}

title "3b.1 the enum carries the vocabulary leaf (introspection)"
SDL_ENUM=$(gql '{ __type(name: "GadgetRelOrderField") { enumValues { name } } }')
echo "$SDL_ENUM" | grep -q 'CREATED_AT' && echo "$SDL_ENUM" | grep -q 'CODE' \
  && ok "GadgetRelOrderField carries CREATED_AT + CODE" \
  || bad "enum incomplete: $(echo "$SDL_ENUM" | head -c 250)"

gql_pass "3b.2 orderBy CREATED_AT/DESC resolves (the declared direction)" \
  'query { gadgetsRel(orderBy: [{field: CREATED_AT, direction: DESC}], first: 1) { edges { node { code } } } }'

gql_reject_field "3b.3 CREATED_AT/ASC → orderBy[CREATED_AT] (direction cut in the resolver)" \
  'query { gadgetsRel(orderBy: [{field: CREATED_AT, direction: ASC}], first: 1) { edges { node { code } } } }' \
  'orderBy[CREATED_AT]'

gql_reject_field "3b.4 CREATED_AT with no direction defaults to ASC → refused the same way" \
  'query { gadgetsRel(orderBy: [{field: CREATED_AT}], first: 1) { edges { node { code } } } }' \
  'orderBy[CREATED_AT]'

gql_reject_field "3b.5 the same member twice → orderBy[CODE]" \
  'query { gadgetsRel(orderBy: [{field: CODE}, {field: NAME}, {field: CODE, direction: DESC}], first: 1) { edges { node { code } } } }' \
  'orderBy[CODE]'

gql_pass "3b.6 distinct members in one ordering stay legal" \
  'query { gadgetsRel(orderBy: [{field: CODE}, {field: NAME, direction: DESC}], first: 1) { edges { node { code } } } }'

title "3b.7 the vocabulary leaf is NOT a where field (it carries no value)"
B=$(gql 'query { gadgetsRel(where: {createdAt: {eq: "2020-01-01"}}, first: 1) { edges { node { code } } } }')
echo "$B" | grep -q '"errors"' && ok "createdAt absent from the where input" \
  || bad "the vocabulary leaf leaked into where: $(echo "$B" | head -c 250)"

title "3b.8 an undeclared member is cut by the SCHEMA, before any resolver"
B=$(gql 'query { gadgetsRel(orderBy: [{field: BOGUS}], first: 1) { edges { node { code } } } }')
echo "$B" | grep -q '"errors"' && ok "unknown enum member rejected at validation" \
  || bad "expected a validation error, got: $(echo "$B" | head -c 250)"

##############################################################################
sec "4. gRPC — runtime rejection on the bare RPC (Connect JSON)"
##############################################################################
# qrpc <rpc-name> <json-body> — Connect JSON call; body → $RPC_BODY, status → $RPC_STATUS
qrpc() {
  local proc="$1" body="$2"
  local tmp; tmp=$(mktemp)
  RPC_STATUS=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    "$GRPC_BASE/qafixtures.v1.QAService/$proc" -d "$body")
  RPC_BODY=$(cat "$tmp"); rm -f "$tmp"
}
grpc_reject() { # grpc_reject <name> <json>
  local name="$1" body="$2"
  title "$name"
  qrpc ListGadgetsBare "$body"
  echo "$RPC_BODY" | grep -q '"invalid_argument"' \
    && ok "$name" || bad "$name (status=$RPC_STATUS body=$(echo "$RPC_BODY" | head -c 200))"
}
grpc_reject "4.1 pagination.first → invalid_argument"            '{"pagination":{"first":"5"}}'
grpc_reject "4.2 pagination.last → invalid_argument"             '{"pagination":{"last":"5"}}'
grpc_reject "4.3 pagination.only_total → invalid_argument"       '{"pagination":{"onlyTotal":true}}'
grpc_reject "4.4 pagination.include_archived → invalid_argument" '{"pagination":{"includeArchived":true}}'
grpc_reject "4.5 pagination.search → invalid_argument"           '{"pagination":{"search":"x"}}'
grpc_reject "4.5a pagination.after → invalid_argument"           '{"pagination":{"after":"cur"}}'
grpc_reject "4.5b pagination.before → invalid_argument"          '{"pagination":{"before":"cur"}}'
grpc_reject "4.6 order_by → invalid_argument"                    '{"orderBy":[{"field":"name"}]}'
grpc_reject "4.7 fields mask → invalid_argument"                 '{"fields":"name"}'
# The bools are proto3 optional: an explicitly-set FALSE carries presence on
# the wire — gated exactly like REST's ?onlyTotal=false on a bare endpoint.
grpc_reject "4.8 pagination.only_total=false → invalid_argument (presence gates)"       '{"pagination":{"onlyTotal":false}}'
grpc_reject "4.9 pagination.include_archived=false → invalid_argument (presence gates)" '{"pagination":{"includeArchived":false}}'

title "4.10 filters-only request passes the gate on the bare RPC"
qrpc ListGadgetsBare '{"filters":{"code":{"conditions":[{"op":"STRING_OP_STARTSWITH","values":["G"]}]}}}'
[ "$RPC_STATUS" = "200" ] && ok "filters pass on the bare RPC" \
  || bad "filters-only must pass (status=$RPC_STATUS body=$(echo "$RPC_BODY" | head -c 200))"

title "4.11 declared RPC honors first (pass-through)"
qrpc ListGadgets '{"pagination":{"first":"1"}}'
[ "$RPC_STATUS" = "200" ] && ok "declared RPC accepts first" \
  || bad "declared first must pass (status=$RPC_STATUS body=$(echo "$RPC_BODY" | head -c 200))"

title "4.12 declared RPC: only_total=false is presence without activation (plain paged read beside first)"
qrpc ListGadgets '{"pagination":{"onlyTotal":false,"first":"1"}}'
[ "$RPC_STATUS" = "200" ] && ok "declared only_total=false stays a no-op beside first" \
  || bad "inactive only_total must not conflict (status=$RPC_STATUS body=$(echo "$RPC_BODY" | head -c 200))"

##############################################################################
sec "4b. gRPC — the SAME vocabulary, folded to proto snake_case"
##############################################################################
# order_by resolves against CriteriaBuilder.Sortable, fed from the Request
# DTO's sort: tags and folded to the proto spelling. It has NO fallback: what
# the DTO did not declare is not orderable here either. The refusal is the
# canonical SchemaViolation carrying the ENTRY as its field name — the gRPC
# dialect of REST's orderBy[<token>], since order_by is already a typed field
# on the request message and the bracket prefix would name nothing.
#
# Both procedures ride the same DTO over different backings (ListGadgets →
# mongo `gadgets`, ListGadgetsRel → the RelationalSource `gadgets_rel`), so
# every case runs twice.

grpc_field_reject() { # grpc_field_reject <name> <proc> <json> <expected field>
  local name="$1" proc="$2" body="$3" want="$4"
  title "$name"
  qrpc "$proc" "$body"
  if echo "$RPC_BODY" | grep -q '"invalid_argument"' \
     && echo "$RPC_BODY" | grep -q 'SchemaViolationNotification' \
     && echo "$RPC_BODY" | grep -qF "\"$want\""; then
    ok "$name (field=$want)"
  else
    bad "$name (want invalid_argument naming $want, got $RPC_STATUS $(echo "$RPC_BODY" | head -c 250))"
  fi
}
grpc_ok() { # grpc_ok <name> <proc> <json>
  local name="$1" proc="$2" body="$3"
  title "$name"
  qrpc "$proc" "$body"
  [ "$RPC_STATUS" = "200" ] && ok "$name" \
    || bad "$name (status=$RPC_STATUS body=$(echo "$RPC_BODY" | head -c 250))"
}

for P in ListGadgets ListGadgetsRel; do
  grpc_ok "4b.1 [$P] order_by created_at desc — the declared direction" \
    "$P" '{"orderBy":[{"field":"created_at","desc":true}],"pagination":{"first":"1"}}'

  grpc_field_reject "4b.2 [$P] created_at ASC is undeclared → field=created_at" \
    "$P" '{"orderBy":[{"field":"created_at"}],"pagination":{"first":"1"}}' 'created_at'

  grpc_field_reject "4b.3 [$P] a path named twice → field=code" \
    "$P" '{"orderBy":[{"field":"code"},{"field":"name"},{"field":"code","desc":true}],"pagination":{"first":"1"}}' 'code'

  grpc_field_reject "4b.4 [$P] an undeclared path → field=bogus" \
    "$P" '{"orderBy":[{"field":"bogus"}],"pagination":{"first":"1"}}' 'bogus'

  grpc_ok "4b.5 [$P] distinct paths in one ordering stay legal" \
    "$P" '{"orderBy":[{"field":"code"},{"field":"name","desc":true}],"pagination":{"first":"1"}}'
done

##############################################################################
hr
printf '\033[1;37mreserved_gate: PASS=%d FAIL=%d\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
