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
hr
printf '\033[1;37mreserved_gate: PASS=%d FAIL=%d\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
