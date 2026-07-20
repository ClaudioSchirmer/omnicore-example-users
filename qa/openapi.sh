#!/usr/bin/env bash
# qa/openapi.sh — end-to-end validation of the framework's OpenAPI surface.
#
# Exercises the two documentation routes the framework registers
# automatically when Wiring.OpenAPI is set:
#
#   GET /openapi.json   → OpenAPI 3.1.0 document
#   GET /docs           → Swagger UI HTML loading /openapi.json
#
# Plus a battery of assertions on the spec content:
#
#   - openapi version is 3.1.0
#   - Every canonical /users/* route appears
#   - The /whoami raw operation appears
#   - The /showcase/users-custom/* manual chain appears
#   - The /echo/* upstream routes DO NOT appear (Hidden: true)
#   - The /livez route appears (auto-registered by the framework)
#   - components.schemas.ErrorEnvelope exists (single dedup envelope)
#   - Auth is NOT advertised on /livez, /whoami, /docs, /openapi.json
#     (Public: true / publicRoutes)
#
# Prerequisites:
#   docker compose -f devops/docker-compose.yml up -d
#   ./devops/debezium/register-connector.sh
#   APP_PROFILE=dev go run -tags 'postgres kafka' ./bootstrap   (in another terminal)
#
# Each case prints DESC/STATUS/PASS|FAIL. Exits non-zero on any failure.

set -u

BASE="${BASE:-http://localhost:8080}"

# Lane-scoped temp files: run.sh runs the "running already" suites for both wave
# lanes (e.g. postgres + mysql) CONCURRENTLY, so a hardcoded /tmp path is clobbered
# mid-write by the sibling lane's identical fetch — the reader then sees a partial
# doc and routes appear to vanish (intermittent RED). Scope by ${BACKEND}.
SPEC_FILE="/tmp/qa-openapi.spec.${BACKEND:-default}.json"
BODY_FILE="/tmp/qa-openapi.body.${BACKEND:-default}"

RED=$'\e[1;31m'
GREEN=$'\e[1;32m'
WHITE=$'\e[1;37m'
RESET=$'\e[0m'

PASS=0
FAIL=0

JQ="$(command -v jq || true)"
if [ -z "${JQ}" ]; then
    echo "${RED}jq is required by qa/openapi.sh — install via 'brew install jq' / 'apt-get install jq'${RESET}"
    exit 2
fi

# show_http hits the BASE+path and asserts the HTTP status.
show_http() {
    local desc="$1" path="$2" expected_status="$3"
    echo "${WHITE}--- ${desc} ---${RESET}"
    echo "REQUEST : GET ${path}"
    local status
    status=$(curl -s -o ${BODY_FILE} -w "%{http_code}" "${BASE}${path}")
    echo "STATUS  : ${status}"
    if [ "${status}" = "${expected_status}" ]; then
        echo "${GREEN}PASS${RESET}"
        PASS=$((PASS + 1))
    else
        echo "${RED}FAIL${RESET} (expected ${expected_status})"
        echo "BODY: $(head -c 200 ${BODY_FILE})"
        FAIL=$((FAIL + 1))
    fi
}

# assert_spec runs a jq query on the cached ${SPEC_FILE} and
# checks the resulting string equals "expected".
assert_spec() {
    local desc="$1" jq_query="$2" expected="$3"
    echo "${WHITE}--- ${desc} ---${RESET}"
    echo "QUERY   : ${jq_query}"
    local got
    got=$("${JQ}" -r "${jq_query}" ${SPEC_FILE})
    echo "GOT     : ${got}"
    if [ "${got}" = "${expected}" ]; then
        echo "${GREEN}PASS${RESET}"
        PASS=$((PASS + 1))
    else
        echo "${RED}FAIL${RESET} (expected ${expected})"
        FAIL=$((FAIL + 1))
    fi
}

# assert_html runs a substring check against ${BODY_FILE}.
assert_html() {
    local desc="$1" needle="$2"
    echo "${WHITE}--- ${desc} ---${RESET}"
    echo "NEEDLE  : ${needle}"
    if grep -qF "${needle}" ${BODY_FILE}; then
        echo "${GREEN}PASS${RESET}"
        PASS=$((PASS + 1))
    else
        echo "${RED}FAIL${RESET} (substring missing from /docs body)"
        FAIL=$((FAIL + 1))
    fi
}

# ─── /openapi.json reachable + valid ─────────────────────────────────────
show_http "/openapi.json reachable" "/openapi.json" 200

# Cache the spec for downstream assertions.
curl -s "${BASE}/openapi.json" > ${SPEC_FILE}
if ! "${JQ}" empty ${SPEC_FILE} 2>/dev/null; then
    echo "${RED}/openapi.json body is not valid JSON; aborting${RESET}"
    head -c 400 ${SPEC_FILE}
    exit 1
fi

assert_spec "openapi version is 3.1.0" '.openapi' "3.1.0"
assert_spec "info.title is set"        '.info.title' "OmniCore Example Users"

# ─── Canonical /users/* surface ──────────────────────────────────────────
assert_spec "/users/ POST exists"              '.paths["/users/"].post.summary'                 "Create a user"
assert_spec "/users/{id} PUT is strict"        '.paths["/users/{id}"].put.requestBody.required' "true"
assert_spec "/users/{id} PATCH is lenient"     '.paths["/users/{id}"].patch.requestBody.required' "false"
assert_spec "/users/{id}/archive registered"   '.paths["/users/{id}/archive"].patch.summary'   "Archive a user (cascade addresses)"
assert_spec "/users/{id}/unarchive registered" '.paths["/users/{id}/unarchive"].patch.summary' "Unarchive a user (restore archived addresses)"
assert_spec "GET /users/ tags Users"           '.paths["/users/"].get.tags[0]'                  "Users"
assert_spec "GET /users/{id} carries 404"      '.paths["/users/{id}"].get.responses["404"].description' "Not Found"

# ─── /whoami raw operation ───────────────────────────────────────────────
assert_spec "/whoami declared"              '.paths["/whoami"].get.summary'   "Returns the authenticated identity"
assert_spec "/whoami response 200 schema"   '.paths["/whoami"].get.responses["200"].content["application/json"].schema."$ref"' "#/components/schemas/WhoamiResponse"

# ─── Manual showcase ─────────────────────────────────────────────────────
assert_spec "POST /showcase/users-custom"        '.paths["/showcase/users-custom/"].post.summary'       "Create a user (manual showcase)"
assert_spec "PUT /showcase/users-custom/{document}" '.paths["/showcase/users-custom/{document}"].put.summary' "Replace a user by document (manual showcase)"

# ─── Echo upstream is Hidden ─────────────────────────────────────────────
assert_spec "/echo/upload absent from paths" '(.paths | has("/echo/upload"))' "false"
assert_spec "/echo/sse absent from paths"    '(.paths | has("/echo/sse"))'    "false"

# ─── /livez auto-registered ─────────────────────────────────────────────
assert_spec "/livez declared by framework" '.paths["/livez"].get.summary' "Liveness probe"
assert_spec "/livez is public (no security)" '(.paths["/livez"].get | has("security"))' "false"

# ─── ErrorEnvelope component ────────────────────────────────────────────
assert_spec "ErrorEnvelope schema declared" '(.components.schemas.ErrorEnvelope.type)' "object"

# ─── /docs HTML reachable + references the spec ──────────────────────────
show_http "/docs reachable" "/docs" 200
assert_html "/docs HTML references /openapi.json" "/openapi.json"
assert_html "/docs HTML carries the service title" "OmniCore Example Users"

# ─── Canonical /users/* — full route catalog ─────────────────────────────
# Every Mount* call in web/user_routes.go must land in the spec. The
# original block above covers POST/PUT/PATCH/archive/unarchive/GET/GET-by-id;
# add the remaining 3 (DELETE + address sub-resource PUT + GET).
assert_spec "DELETE /users/{id} registered"                 '.paths["/users/{id}"].delete.summary'                              "Hard-delete a user"
assert_spec "PUT /users/{id}/addresses/{addressId}"         '.paths["/users/{id}/addresses/{addressId}"].put.summary'          "Replace one address inside a user (preserve address id)"
assert_spec "GET /users/{id}/addresses/{addressId}"         '.paths["/users/{id}/addresses/{addressId}"].get.summary'          "Get one address of a user by id"

# ─── Canonical /users/* — auto-added error responses on body verbs ────────
# Per "HTTP status mapping": every body-carrying route auto-adds 400+422+500;
# every {id}-carrying route adds 404. None of these is declared by hand.
assert_spec "POST /users/ auto-adds 400"  '.paths["/users/"].post.responses["400"].description'  "Bad Request"
assert_spec "POST /users/ auto-adds 422"  '.paths["/users/"].post.responses["422"].description'  "Unprocessable Entity"
assert_spec "POST /users/ auto-adds 500"  '.paths["/users/"].post.responses["500"].description'  "Internal Server Error"
assert_spec "PUT /users/{id} auto-adds 404"  '.paths["/users/{id}"].put.responses["404"].description'  "Not Found"
assert_spec "DELETE /users/{id} auto-adds 404"  '.paths["/users/{id}"].delete.responses["404"].description'  "Not Found"
assert_spec "PATCH /users/{id}/archive auto-adds 422"  '.paths["/users/{id}/archive"].patch.responses["422"].description'  "Unprocessable Entity"

# ─── Canonical request bodies — $ref into components.schemas ──────────────
# The framework's generator must reference InsertUserRequest by name (not inline).
assert_spec "POST /users body refs InsertUserRequest"  '.paths["/users/"].post.requestBody.content["application/json"].schema."$ref"'  "#/components/schemas/InsertUserRequest"
assert_spec "PUT /users/{id} body refs UpdateUserRequest"  '.paths["/users/{id}"].put.requestBody.content["application/json"].schema."$ref"'  "#/components/schemas/UpdateUserRequest"
assert_spec "PATCH /users/{id} body refs PatchUserRequest"  '.paths["/users/{id}"].patch.requestBody.content["application/json"].schema."$ref"'  "#/components/schemas/PatchUserRequest"

# ─── Canonical success responses — $ref into components.schemas ───────────
assert_spec "POST /users 201 refs InsertUserResponse"  '.paths["/users/"].post.responses["201"].content["application/json"].schema.properties.data."$ref"'  "#/components/schemas/InsertUserResponse"
assert_spec "PUT /users/{id} 200 refs UpdateUserResponse"  '.paths["/users/{id}"].put.responses["200"].content["application/json"].schema.properties.data."$ref"'  "#/components/schemas/UpdateUserResponse"

# ─── Paged success envelopes — data:array + pagination ────────────────────
# GET /users uses QueryWithParamsSpec; the envelope must carry
# data as an array of FindUsersByParamsResponse AND a top-level
# pagination property referencing the PaginationInfo schema. Mirrors
# fwweb.RespondPaged runtime shape.
assert_spec "GET /users/ data is array"             '.paths["/users/"].get.responses["200"].content["application/json"].schema.properties.data.type'              "array"
assert_spec "GET /users/ data items ref FindUsersByParamsResponse" '.paths["/users/"].get.responses["200"].content["application/json"].schema.properties.data.items."$ref"' "#/components/schemas/FindUsersByParamsResponse"
assert_spec "GET /users/ pagination refs PaginationInfo" '.paths["/users/"].get.responses["200"].content["application/json"].schema.properties.pagination."$ref"' "#/components/schemas/PaginationInfo"
assert_spec "PaginationInfo is in components.schemas" '(.components.schemas.PaginationInfo.type)' "object"
# Manual paged route (RouteSpecOfPaged) mirrors the canonical shape so
# canonical-vs-manual stays feature-equivalent on the spec surface.
assert_spec "GET /showcase/users-custom/ data is array"   '.paths["/showcase/users-custom/"].get.responses["200"].content["application/json"].schema.properties.data.type' "array"
assert_spec "GET /showcase/users-custom/ pagination present" '.paths["/showcase/users-custom/"].get.responses["200"].content["application/json"].schema.properties.pagination."$ref"' "#/components/schemas/PaginationInfo"
# By-id endpoints stay singular (no array, no pagination).
assert_spec "GET /users/{id} data NOT array"        '.paths["/users/{id}"].get.responses["200"].content["application/json"].schema.properties.data.type' "null"
assert_spec "GET /users/{id} pagination absent"     '(.paths["/users/{id}"].get.responses["200"].content["application/json"].schema.properties | has("pagination"))' "false"
assert_spec "GET /showcase/users-custom/{document} pagination absent" '(.paths["/showcase/users-custom/{document}"].get.responses["200"].content["application/json"].schema.properties | has("pagination"))' "false"

# ─── Component schemas — every named DTO is in the schema dictionary ──────
assert_spec "InsertUserRequest is in components.schemas"  '(.components.schemas.InsertUserRequest.type)'  "object"
assert_spec "UpdateUserRequest is in components.schemas"  '(.components.schemas.UpdateUserRequest.type)'  "object"
assert_spec "PatchUserRequest is in components.schemas"   '(.components.schemas.PatchUserRequest.type)'   "object"
assert_spec "InsertUserResponse is in components.schemas" '(.components.schemas.InsertUserResponse.type)' "object"
assert_spec "FindUserByIDResponse is in components.schemas" '(.components.schemas.FindUserByIDResponse.type)' "object"
assert_spec "FindUsersByParamsResponse is in components.schemas" '(.components.schemas.FindUsersByParamsResponse.type)' "object"

# ─── Manual showcase — full route catalog ─────────────────────────────────
# Mirrors the canonical with the email-keyed identifier. user_custom_routes.go
# mounts 10 routes; the original block covers POST + PUT — assert the rest.
assert_spec "PATCH /showcase/users-custom/{document}"                  '.paths["/showcase/users-custom/{document}"].patch.summary'                                       "Patch a user by document (manual showcase)"
assert_spec "PATCH /showcase/users-custom/{document}/archive"          '.paths["/showcase/users-custom/{document}/archive"].patch.summary'                               "Archive a user by document (manual showcase)"
assert_spec "PATCH /showcase/users-custom/{document}/unarchive"        '.paths["/showcase/users-custom/{document}/unarchive"].patch.summary'                             "Unarchive a user by document (manual showcase)"
assert_spec "DELETE /showcase/users-custom/{document}"                 '.paths["/showcase/users-custom/{document}"].delete.summary'                                      "Hard-delete a user by document (manual showcase)"
assert_spec "GET /showcase/users-custom/"                           '.paths["/showcase/users-custom/"].get.summary'                                                "List users (manual showcase)"
assert_spec "GET /showcase/users-custom/{document}"                    '.paths["/showcase/users-custom/{document}"].get.summary'                                         "Get a user by document (manual showcase)"
assert_spec "PUT /showcase/users-custom/{document}/addresses/..."      '.paths["/showcase/users-custom/{document}/addresses/{addressId}"].put.summary'                   "Replace one address inside a user (manual showcase)"
assert_spec "GET /showcase/users-custom/{document}/addresses/..."      '.paths["/showcase/users-custom/{document}/addresses/{addressId}"].get.summary'                   "Get one address of a user by document (manual showcase)"

# ─── Hidden upstream demos — must NOT appear in the spec ──────────────────
# /echo/* (original asserts /upload + /sse). Cover the remaining three.
assert_spec "/echo/stream/{size} absent"    '(.paths | has("/echo/stream/{size}"))'    "false"
assert_spec "/echo/multipart absent"        '(.paths | has("/echo/multipart"))'        "false"
assert_spec "/echo/signed absent"           '(.paths | has("/echo/signed"))'           "false"
# /showcase/keycloak/* and /showcase/httpclient/* — all Hidden: true.
assert_spec "/showcase/keycloak/realm absent"             '(.paths | has("/showcase/keycloak/realm"))'             "false"
assert_spec "/showcase/keycloak/admin/{id} absent"        '(.paths | has("/showcase/keycloak/admin/{id}"))'        "false"
assert_spec "/showcase/keycloak/tenant/whoami absent"     '(.paths | has("/showcase/keycloak/tenant/whoami"))'     "false"
assert_spec "/showcase/httpclient/sse absent"             '(.paths | has("/showcase/httpclient/sse"))'             "false"
assert_spec "/showcase/httpclient/signed absent"          '(.paths | has("/showcase/httpclient/signed"))'          "false"
assert_spec "/showcase/httpclient/multipart absent"       '(.paths | has("/showcase/httpclient/multipart"))'       "false"
assert_spec "/showcase/httpclient/download-stream/... absent" '(.paths | has("/showcase/httpclient/download-stream/{size}"))' "false"
assert_spec "/showcase/httpclient/upload-stream absent"   '(.paths | has("/showcase/httpclient/upload-stream"))'   "false"
assert_spec "/showcase/httpclient/with-config-override absent" '(.paths | has("/showcase/httpclient/with-config-override"))' "false"
assert_spec "/showcase/httpclient/inline-bearer absent"   '(.paths | has("/showcase/httpclient/inline-bearer"))'   "false"

# ─── Documentation routes themselves don't appear in .paths ───────────────
# Registered via openapi.Register, not Mount/MountRaw.
assert_spec "/openapi.json absent from paths" '(.paths | has("/openapi.json"))' "false"
assert_spec "/docs absent from paths"         '(.paths | has("/docs"))'         "false"

# ─── ErrorEnvelope is referenced by error responses, not just declared ────
assert_spec "ErrorEnvelope referenced by /users 400"   '.paths["/users/"].post.responses["400"].content["application/json"].schema."$ref"'  "#/components/schemas/ErrorEnvelope"
assert_spec "ErrorEnvelope referenced by /users 422"   '.paths["/users/"].post.responses["422"].content["application/json"].schema."$ref"'  "#/components/schemas/ErrorEnvelope"
assert_spec "ErrorEnvelope referenced by /users 500"   '.paths["/users/"].post.responses["500"].content["application/json"].schema."$ref"'  "#/components/schemas/ErrorEnvelope"

# ─── Descriptions, parameters ─────────────────────────────────────────────
# Descriptions on canonical routes are intentional (consumer-facing docs).
assert_spec "POST /users description non-empty" '(.paths["/users/"].post.description | length > 0)' "true"

# Path parameters are auto-emitted from :id segments + path:"..." tags.
assert_spec "PUT /users/{id} declares {id} parameter"   '[.paths["/users/{id}"].put.parameters[]? | select(.in == "path" and .name == "id")] | length' "1"
assert_spec "GET /users/{id}/addresses/{addressId} declares both" '[.paths["/users/{id}/addresses/{addressId}"].get.parameters[]? | select(.in == "path")] | length' "2"
assert_spec "PUT /showcase/users-custom/{document} declares {document}" '[.paths["/showcase/users-custom/{document}"].put.parameters[]? | select(.in == "path" and .name == "document")] | length' "1"

# Query parameters on the list endpoint — every `query:"..."` tag on
# FindUsersByParamsRequest surfaces, including the operator-specific suffixes
# (name, name.ne, name.in, name.startswith, ...).
assert_spec "GET /users/ declares limit query"    '[.paths["/users/"].get.parameters[]? | select(.in == "query" and .name == "limit")] | length' "1"
assert_spec "GET /users/ declares name.eq query"  '[.paths["/users/"].get.parameters[]? | select(.in == "query" and .name == "name")] | length' "1"
assert_spec "GET /users/{id} declares includeArchived query" '[.paths["/users/{id}"].get.parameters[]? | select(.in == "query" and .name == "includeArchived")] | length' "1"

# ─── Tabular export (/users.csv, /users.xlsx) parameter honesty ──────────
# The export routes reuse FindUsersByParamsRequest but accept-and-ignore
# pagination (limit/after/before/onlyTotal) — the *Spec wrappers list those on
# RouteSpec.OmittedQueryParams so the generator strips them. The HONORED knobs
# (filters + fields/sort/search/includeArchived) must still render, and the 200
# must be a file download, not the JSON envelope. A route that renders a knob it
# silently ignores is a contract lie; these cases pin the omission.
assert_spec "/users.csv is documented"                   '.paths | has("/users.csv")' "true"
assert_spec "/users.xlsx is documented"                  '.paths | has("/users.xlsx")' "true"
# Honored filters/controls still render on the export.
assert_spec "GET /users.csv declares name filter"        '[.paths["/users.csv"].get.parameters[]? | select(.in == "query" and .name == "name")] | length' "1"
assert_spec "GET /users.csv declares name.startswith"    '[.paths["/users.csv"].get.parameters[]? | select(.in == "query" and .name == "name.startswith")] | length' "1"
assert_spec "GET /users.csv declares email.in filter"    '[.paths["/users.csv"].get.parameters[]? | select(.in == "query" and .name == "email.in")] | length' "1"
assert_spec "GET /users.csv declares fields control"     '[.paths["/users.csv"].get.parameters[]? | select(.in == "query" and .name == "fields")] | length' "1"
assert_spec "GET /users.csv declares sort control"       '[.paths["/users.csv"].get.parameters[]? | select(.in == "query" and .name == "sort")] | length' "1"
assert_spec "GET /users.csv declares search control"     '[.paths["/users.csv"].get.parameters[]? | select(.in == "query" and .name == "search")] | length' "1"
assert_spec "GET /users.csv declares includeArchived"    '[.paths["/users.csv"].get.parameters[]? | select(.in == "query" and .name == "includeArchived")] | length' "1"
# Ignored pagination knobs are STRIPPED — Swagger must not advertise them.
assert_spec "GET /users.csv omits limit param"           '[.paths["/users.csv"].get.parameters[]? | select(.in == "query" and .name == "limit")] | length' "0"
assert_spec "GET /users.csv omits after param"           '[.paths["/users.csv"].get.parameters[]? | select(.in == "query" and .name == "after")] | length' "0"
assert_spec "GET /users.csv omits before param"          '[.paths["/users.csv"].get.parameters[]? | select(.in == "query" and .name == "before")] | length' "0"
assert_spec "GET /users.csv omits onlyTotal param"       '[.paths["/users.csv"].get.parameters[]? | select(.in == "query" and .name == "onlyTotal")] | length' "0"
assert_spec "GET /users.xlsx omits limit param too"      '[.paths["/users.xlsx"].get.parameters[]? | select(.in == "query" and .name == "limit")] | length' "0"
assert_spec "GET /users.xlsx declares name filter too"   '[.paths["/users.xlsx"].get.parameters[]? | select(.in == "query" and .name == "name")] | length' "1"
# 200 is a file download (FileResponse), not the JSON envelope.
assert_spec "GET /users.csv 200 is a text/csv download"  '[.paths["/users.csv"].get.responses["200"].content | keys[] | select(startswith("text/csv"))] | length' "1"
assert_spec "GET /users.csv 200 is NOT a JSON envelope"  '.paths["/users.csv"].get.responses["200"].content | has("application/json")' "false"
assert_spec "GET /users.xlsx 200 is a spreadsheet download" '[.paths["/users.xlsx"].get.responses["200"].content | keys[] | select(startswith("application/vnd.openxmlformats"))] | length' "1"

# ─── Tag coverage ────────────────────────────────────────────────────────
# Three distinct tag groups expected: Users, Whoami, Manual Users.
assert_spec "GET /whoami carries Auth tag" '.paths["/whoami"].get.tags[0]' "Auth"
assert_spec "POST /showcase/users-custom carries Users — manual showcase tag" '.paths["/showcase/users-custom/"].post.tags[0]' "Users — manual showcase"

# ─── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "${WHITE}=========== qa/openapi.sh ===========${RESET}"
echo "${GREEN}PASS: ${PASS}${RESET}"
if [ "${FAIL}" -gt 0 ]; then
    echo "${RED}FAIL: ${FAIL}${RESET}"
    exit 1
fi
echo "${WHITE}All ${PASS} cases passed${RESET}"
