#!/usr/bin/env bash
# qa/graphql.sh — end-to-end validation of the framework's GraphQL surface.
#
# GraphQL is its OWN web surface (POST /graphql), separate from REST/OpenAPI:
# it reuses the same application handlers but never appears in the Swagger
# document and is not policed by the REST route scans. This suite drives the
# endpoint the example wires via Wiring.GraphQL = NewGraphQL(d):
#
#   Query    users(where, first, after, orderBy, ...) → Relay connection
#   Mutation createUser(input)       → InsertUserResponse
#   Mutation archiveUser(id) / deleteUser(id) → MutationResult
#
# Coverage:
#   - Introspection (__schema / __type) answered (graphql.introspection: true)
#   - GraphiQL playground served at /graphql/ui (graphql.playground: true)
#   - GraphQL route ABSENT from /openapi.json (own surface, never in Swagger)
#   - All SIX write verbs (parity with /users/*): createUser (Mutation),
#     updateUser + patchUser (MutationWithBodyID, PUT/PATCH — id + input),
#     archiveUser + unarchiveUser + deleteUser (MutationByID → MutationResult)
#   - createUser persists; the same record appears on the read side after the
#     CDC pipeline materializes it (Debezium → Kafka → Mongo)
#   - where filter folds identically to REST; edges[].cursor populated (Relay)
#   - validation errors travel in errors[] with HTTP 200 (GraphQL convention),
#     carrying the full notification triple in extensions (semantic /
#     notificationKey / field) — a domain rule (invalid email → Validation) and
#     a stale keyset cursor (→ Schema, NOT 500/Internal) both asserted
#
# Prerequisites (same as e2e.sh):
#   docker compose -f devops/docker-compose.yml up -d
#   ./devops/debezium/register-connector.sh
#   APP_PROFILE=dev go run -tags postgres ./bootstrap   (in another terminal)
#
# Each case prints DESC/STATUS/PASS|FAIL. Exits non-zero on any failure.

set -u

BASE="${BASE:-http://localhost:8080}"
CDC_WAIT_SEC="${CDC_WAIT_SEC:-4}"

RED=$'\e[1;31m'
GREEN=$'\e[1;32m'
WHITE=$'\e[1;37m'
RESET=$'\e[0m'

PASS=0
FAIL=0

JQ="$(command -v jq || true)"
if [ -z "${JQ}" ]; then
    echo "${RED}jq is required by qa/graphql.sh — install via 'brew install jq' / 'apt-get install jq'${RESET}"
    exit 2
fi

EMAIL="gql-$(date +%s)@omnicore.test"
USER_ID=""

# gql posts a GraphQL query/mutation, caching the JSON response in
# /tmp/qa-graphql.body and echoing the HTTP status.
gql() {
    local query="$1"
    local payload
    payload=$(jq -nc --arg q "${query}" '{query:$q}')
    curl -s -o /tmp/qa-graphql.body -w "%{http_code}" \
        -H "Content-Type: application/json" \
        -X POST "${BASE}/graphql" -d "${payload}"
}

# assert_jq runs a jq filter over the cached response and compares to expected.
assert_jq() {
    local desc="$1" filter="$2" expected="$3"
    echo "${WHITE}--- ${desc} ---${RESET}"
    local got
    got=$(jq -r "${filter}" /tmp/qa-graphql.body 2>/dev/null)
    echo "QUERY   : ${filter}"
    echo "GOT     : ${got}"
    if [ "${got}" = "${expected}" ]; then
        echo "${GREEN}PASS${RESET}"; PASS=$((PASS + 1))
    else
        echo "${RED}FAIL${RESET} (expected ${expected})"
        echo "BODY: $(head -c 300 /tmp/qa-graphql.body)"
        FAIL=$((FAIL + 1))
    fi
}

# assert_jq_true checks a jq boolean filter evaluates to true.
assert_jq_true() {
    local desc="$1" filter="$2"
    assert_jq "${desc}" "${filter}" "true"
}

# ── 1. Health sanity ────────────────────────────────────────────────────────
echo "${WHITE}--- health ---${RESET}"
hs=$(curl -s -o /dev/null -w "%{http_code}" "${BASE}/health")
if [ "${hs}" = "200" ]; then echo "${GREEN}PASS${RESET}"; PASS=$((PASS+1)); else echo "${RED}FAIL${RESET} ($hs)"; FAIL=$((FAIL+1)); fi

# ── 2. Introspection: __schema.queryType ────────────────────────────────────
gql 'query { __schema { queryType { name } mutationType { name } } }' >/dev/null
assert_jq "introspection __schema.queryType.name" '.data.__schema.queryType.name' "Query"
assert_jq "introspection __schema.mutationType.name" '.data.__schema.mutationType.name' "Mutation"

# ── 3. Introspection: __type(name:"User") exposes fields ────────────────────
gql 'query { __type(name: "User") { name kind fields { name } } }' >/dev/null
assert_jq "__type User kind" '.data.__type.kind' "OBJECT"
assert_jq_true "__type User has id/name/email fields" \
    '[.data.__type.fields[].name] as $f | (["id","name","email"] - $f) == []'

# ── 4. Playground served at /graphql/ui ─────────────────────────────────────
echo "${WHITE}--- playground GET /graphql/ui ---${RESET}"
ui_status=$(curl -s -o /tmp/qa-graphql.ui -w "%{http_code}" "${BASE}/graphql/ui")
echo "STATUS  : ${ui_status}"
if [ "${ui_status}" = "200" ] && grep -q "GraphiQL" /tmp/qa-graphql.ui; then
    echo "${GREEN}PASS${RESET}"; PASS=$((PASS+1))
else
    echo "${RED}FAIL${RESET} (status ${ui_status} / GraphiQL marker)"; FAIL=$((FAIL+1))
fi

# ── 5. GraphQL route is ABSENT from the Swagger document ────────────────────
echo "${WHITE}--- /graphql absent from /openapi.json ---${RESET}"
curl -s -o /tmp/qa-graphql.spec "${BASE}/openapi.json"
if jq -e '.paths | keys | any(test("graphql"))' /tmp/qa-graphql.spec >/dev/null 2>&1; then
    echo "${RED}FAIL${RESET} (GraphQL leaked into the OpenAPI spec)"; FAIL=$((FAIL+1))
else
    echo "${GREEN}PASS${RESET}"; PASS=$((PASS+1))
fi

# ── 6. createUser mutation persists ─────────────────────────────────────────
gql "mutation { createUser(input: {
        name: \"GraphQL Tester\",
        email: \"${EMAIL}\",
        phone: \"14155552671\",
        addresses: [{ label: \"home\", street: \"1 Infinite Loop\", number: \"1\",
                      neighborhood: \"Mariani\", city: \"Cupertino\", state: \"CA\",
                      zipCode: \"95014\", country: \"US\" }]
     }) { id name email } }" >/dev/null
assert_jq "createUser returns the email" '.data.createUser.email' "${EMAIL}"
USER_ID=$(jq -r '.data.createUser.id' /tmp/qa-graphql.body 2>/dev/null)
echo "USER_ID : ${USER_ID}"

# ── 7. Read side materializes (CDC) and the where filter folds like REST ────
echo "Waiting ${CDC_WAIT_SEC}s for the CDC pipeline (Debezium → Kafka → Mongo)…"
sleep "${CDC_WAIT_SEC}"
gql "query { users(where: { email: { eq: \"${EMAIL}\" } }, first: 10) {
        edges { node { id name email } cursor }
        pageInfo { hasNextPage startCursor endCursor }
        totalCount
     } }" >/dev/null
assert_jq "users where email.eq returns the created node" \
    '.data.users.edges[0].node.email' "${EMAIL}"
assert_jq_true "Relay edges[].cursor is populated (per-item keyset cursor)" \
    '(.data.users.edges[0].cursor // "") | length > 0'
assert_jq_true "connection carries pageInfo + totalCount" \
    '(.data.users.pageInfo != null) and (.data.users.totalCount >= 1)'

# ── 8. Bare connection shape (no where) ─────────────────────────────────────
gql 'query { users(first: 1) { edges { node { id } } pageInfo { hasNextPage } totalCount } }' >/dev/null
assert_jq_true "users(first:1) returns a well-formed connection" \
    '(.data.users.edges | type == "array") and (.data.users.totalCount | type == "number")'

# ── 9. Validation: undeclared operator on a declared field → errors[] (200) ─
echo "${WHITE}--- undeclared operator rejected by validation ---${RESET}"
vstatus=$(gql 'query { users(where: { email: { contains: "x" } }) { totalCount } }')
echo "STATUS  : ${vstatus}"
if [ "${vstatus}" = "200" ] && jq -e '.errors | length > 0' /tmp/qa-graphql.body >/dev/null 2>&1; then
    echo "${GREEN}PASS${RESET}"; PASS=$((PASS+1))
else
    echo "${RED}FAIL${RESET} (expected 200 + errors[])"; echo "BODY: $(head -c 300 /tmp/qa-graphql.body)"; FAIL=$((FAIL+1))
fi

# ── 10. Validation: unknown root field → errors[] (200) ─────────────────────
gql 'query { bogusRootField { totalCount } }' >/dev/null
assert_jq_true "unknown root field surfaces an error" '.errors | length > 0'

# ── Write verbs (the remaining 5 of the 6) against the persisted record ─────
if [ -n "${USER_ID}" ] && [ "${USER_ID}" != "null" ]; then

    # ── 11. updateUser (PUT, MutationWithBodyID, strict body) ───────────────────
    # FullBody → every input field is NonNull, so the whole body is sent.
    # Email is immutable on update (domain rule), so it is kept identical.
    gql "mutation { updateUser(id: \"${USER_ID}\", input: {
            name: \"GraphQL Updated\",
            email: \"${EMAIL}\",
            phone: \"14155550000\",
            addresses: [{ label: \"work\", street: \"2 Loop\", number: \"2\",
                          neighborhood: \"Centro\", city: \"Cupertino\", state: \"CA\",
                          zipCode: \"95015\", country: \"US\" }]
         }) { id name email } }" >/dev/null
    assert_jq "updateUser applies the new name" '.data.updateUser.name' "GraphQL Updated"
    assert_jq "updateUser keeps the (immutable) email" '.data.updateUser.email' "${EMAIL}"

    # ── 12. patchUser (PATCH, MutationWithBodyID, lenient body) ─────────────────
    gql "mutation { patchUser(id: \"${USER_ID}\", input: { name: \"GraphQL Patched\" }) { id name } }" >/dev/null
    assert_jq "patchUser applies the partial name" '.data.patchUser.name' "GraphQL Patched"

    # ── 13. archiveUser (MutationByID → MutationResult) ─────────────────────
    gql "mutation { archiveUser(id: \"${USER_ID}\") { success id } }" >/dev/null
    assert_jq_true "archiveUser returns success" '.data.archiveUser.success == true'

    # ── 14. unarchiveUser (MutationByID → MutationResult) ───────────────────
    gql "mutation { unarchiveUser(id: \"${USER_ID}\") { success } }" >/dev/null
    assert_jq_true "unarchiveUser returns success" '.data.unarchiveUser.success == true'

    # ── 15. deleteUser (MutationByID → MutationResult) — cleanup ────────────
    gql "mutation { deleteUser(id: \"${USER_ID}\") { success } }" >/dev/null
    assert_jq_true "deleteUser returns success" '.data.deleteUser.success == true'
else
    echo "${RED}FAIL${RESET} (no USER_ID captured — skipping write verbs)"; FAIL=$((FAIL+1))
fi

# ── 16. Notifications surface legibly in errors[].extensions ────────────────
# A domain validation notification must travel with its full triple
# (semantic / notificationKey / field) — NOT the opaque internal-error shape.
# createUser with a malformed email fires InvalidEmailNotification (Validation).
gql "mutation { createUser(input: {
        name: \"Bad Email\", email: \"not-an-email\", phone: \"14155552671\",
        addresses: [{ label: \"home\", street: \"1 Loop\", number: \"1\",
                      neighborhood: \"X\", city: \"Y\", state: \"CA\",
                      zipCode: \"95014\", country: \"US\" }]
     }) { id } }" >/dev/null
assert_jq "invalid email → semantic Validation" '.errors[0].extensions.semantic' "Validation"
assert_jq "invalid email → notificationKey InvalidEmailNotification" \
    '.errors[0].extensions.notificationKey' "InvalidEmailNotification"
assert_jq_true "invalid email → field is the email field" \
    '((.errors[0].extensions.field // "") | ascii_downcase) == "email"'
# extensions mirror the REST ErrorMessage in full: the translated fieldLabel
# (from the labelKey:"UserEmailField" tag, ENG default → "Email") and the echoed
# value travel alongside the triple — not only semantic/notificationKey/field.
assert_jq "invalid email → fieldLabel mirrors REST (labelKey UserEmailField)" \
    '.errors[0].extensions.fieldLabel' "Email"
assert_jq "invalid email → value echoes the offending input" \
    '.errors[0].extensions.value' "not-an-email"
# The flat GraphQL errors[] has no grouping level, so the REST envelope's
# grouping context (the translated context name) rides per message in
# extensions instead — closing the last data gap with the REST surface.
assert_jq "invalid email → context mirrors REST grouping (translated 'User')" \
    '.errors[0].extensions.context' "User"

# ── 17. Count-only (totalCount-only) + pagination arg → pre-dispatch conflict ─
# A totalCount-only selection maps to count-only (ReadCriteria.OnlyTotal). A
# pagination/sort argument alongside it (here first + after) is a conflict —
# there is no page to order or seek into when only the count is asked — rejected
# pre-dispatch with a legible SchemaViolationNotification (semantic Schema),
# parity with REST's onlyTotalConflicts. The cursor below decodes cleanly but is
# moot: the conflict fires before the reader ever sees it.
STALE_CURSOR="eyJ2IjogMSwgImsiOiBbIngiXSwgImgiOiAiZGVhZGJlZWYifQ=="
gql "query { users(first: 1, after: \"${STALE_CURSOR}\") { totalCount } }" >/dev/null
assert_jq "count-only + pagination → semantic Schema (not Internal)" '.errors[0].extensions.semantic' "Schema"
assert_jq "count-only + pagination → notificationKey SchemaViolationNotification" \
    '.errors[0].extensions.notificationKey' "SchemaViolationNotification"
assert_jq_true "count-only + pagination → message is legible (not 'internal server error')" \
    '((.errors[0].message // "") != "internal server error")'

# ── 17b. Stale cursor on a real (edges) read → reader-side Schema rejection ───
# An edges selection is a full read (not count-only), so the stale cursor is NOT
# short-circuited by the count-only conflict above — it reaches the reader,
# which returns the same legible SchemaViolationNotification (semantic Schema)
# instead of a 500/Internal. GraphQL has no pre-dispatch cursor check on a real
# read; the typed rejection comes from the reader (infra.InvalidCursorError).
gql "query { users(first: 1, after: \"${STALE_CURSOR}\") { edges { node { id } } } }" >/dev/null
assert_jq "stale cursor (edges read) → semantic Schema (not Internal)" '.errors[0].extensions.semantic' "Schema"
assert_jq "stale cursor (edges read) → notificationKey SchemaViolationNotification" \
    '.errors[0].extensions.notificationKey' "SchemaViolationNotification"

# ── 17c. Count-only alone (no pagination) → just the count, no items ──────────
# The common count-only shape: totalCount only, no pagination arg → short-circuit
# to a count. The envelope carries totalCount and no edges key.
gql 'query { users { totalCount } }' >/dev/null
assert_jq_true "count-only alone → totalCount is a number, edges absent" \
    '(.data.users.totalCount | type == "number") and (.data.users | has("edges") | not)'

# ── 18. Relay pagination direction (first/after forward, last/before backward) ─
# last: N is a well-formed backward request — it pages from the END of the set
# and returns a valid connection (the per-row ordering correctness is covered by
# the framework's reader integration test).
gql 'query { users(last: 1) { edges { node { id } } pageInfo { hasPreviousPage } totalCount } }' >/dev/null
assert_jq_true "users(last:1) returns a well-formed backward connection" \
    '(.data.users.edges | type == "array") and (.data.users.totalCount | type == "number")'

# Forward (first/after) and backward (last/before) are mutually exclusive — every
# mix is rejected pre-dispatch with a SchemaViolationNotification (semantic
# Schema), the handler never runs. The after+before pair is included: it is now a
# clean 400 here, not the reader's defense-in-depth 500/Internal.
for combo in \
    'first: 1, last: 1' \
    "last: 1, after: \"${STALE_CURSOR}\"" \
    "after: \"${STALE_CURSOR}\", before: \"${STALE_CURSOR}\""; do
    gql "query { users(${combo}) { edges { node { id } } } }" >/dev/null
    assert_jq "direction mix [${combo}] → semantic Schema (not Internal)" \
        '.errors[0].extensions.semantic' "Schema"
    assert_jq "direction mix [${combo}] → notificationKey SchemaViolationNotification" \
        '.errors[0].extensions.notificationKey' "SchemaViolationNotification"
done

# A non-positive page size is rejected too — parity with REST rejecting ?limit= <= 0.
gql 'query { users(first: 0) { edges { node { id } } } }' >/dev/null
assert_jq "first: 0 (non-positive page size) → semantic Schema" \
    '.errors[0].extensions.semantic' "Schema"

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "${WHITE}=== GraphQL QA: ${PASS} passed, ${FAIL} failed ===${RESET}"
[ "${FAIL}" -eq 0 ] || exit 1
