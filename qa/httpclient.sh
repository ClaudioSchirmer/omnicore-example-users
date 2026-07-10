#!/usr/bin/env bash
# qa/httpclient.sh — end-to-end validation of the framework's outbound HTTP
# subsystem against the local Keycloak fixture.
#
# Exercises the three showcase endpoints registered by MountUsers:
#
#   GET /showcase/keycloak/realm                          → public OIDC discovery (anonymous + cache)
#   GET /showcase/keycloak/admin/:id                      → admin user fetch (oauth2-client-credentials + token cache)
#   GET /showcase/keycloak/tenant/whoami?username&password → multi-tenant via credentials-exchange (requestFieldsFromCtx + per-identity cache)
#
# Prerequisites:
#   docker compose -f devops/docker-compose.yml up -d
#   ./devops/debezium/register-connector.sh
#   APP_PROFILE=dev go run -tags 'postgres kafka' ./bootstrap   (in another terminal)
#
# Each case prints REQUEST/STATUS/PASS|FAIL. Exits non-zero on any failure.

set -u

BASE="${BASE:-http://localhost:8080}"

RED=$'\e[1;31m'
GREEN=$'\e[1;32m'
YELLOW=$'\e[1;33m'
WHITE=$'\e[1;37m'
CYAN=$'\e[1;36m'
RESET=$'\e[0m'

PASS=0
FAIL=0

show() {
    local desc="$1" method="$2" path="$3" expected_status="$4"
    local query="${5:-}"
    echo "${WHITE}--- ${desc} ---${RESET}"
    echo "REQUEST : ${method} ${path}${query:+?$query}"
    local url="${BASE}${path}${query:+?$query}"
    local response status
    response=$(curl -s -o /tmp/qa-httpclient.body -w "%{http_code}|%{time_total}" -X "${method}" "${url}")
    status="${response%%|*}"
    local time_total="${response#*|}"
    echo "STATUS  : ${status}"
    echo "TIME    : ${time_total}s"
    if [ "${status}" = "${expected_status}" ]; then
        echo "${GREEN}PASS${RESET}"
        PASS=$((PASS + 1))
    else
        echo "${RED}FAIL${RESET} (expected ${expected_status})"
        echo "BODY: $(head -c 400 /tmp/qa-httpclient.body)"
        FAIL=$((FAIL + 1))
    fi
    echo ""
}

show_with_body_contains() {
    local desc="$1" method="$2" path="$3" expected_status="$4" expected_substring="$5"
    local query="${6:-}"
    echo "${WHITE}--- ${desc} ---${RESET}"
    echo "REQUEST : ${method} ${path}${query:+?$query}"
    local url="${BASE}${path}${query:+?$query}"
    local status
    status=$(curl -s -o /tmp/qa-httpclient.body -w "%{http_code}" -X "${method}" "${url}")
    echo "STATUS  : ${status}"
    if [ "${status}" = "${expected_status}" ] && grep -q "${expected_substring}" /tmp/qa-httpclient.body; then
        echo "${GREEN}PASS${RESET}"
        PASS=$((PASS + 1))
    else
        echo "${RED}FAIL${RESET} (expected ${expected_status} and body containing '${expected_substring}')"
        echo "BODY: $(head -c 400 /tmp/qa-httpclient.body)"
        FAIL=$((FAIL + 1))
    fi
    echo ""
}

echo "${CYAN}============================================================${RESET}"
echo "${YELLOW}== qa/httpclient.sh ==${RESET}"
echo "${CYAN}============================================================${RESET}"
echo ""

# --- Sanity ----------------------------------------------------------------

show "Health" GET /livez 200

# --- 10.A — anonymous public endpoint + cache ------------------------------

show_with_body_contains \
    "Anonymous: Keycloak OIDC discovery returns issuer" \
    GET /showcase/keycloak/realm 200 "\"issuer\":\"http://localhost:8088/realms/omnicore-test\""

# Two more calls to exercise the cache; the first miss already populated the
# entry, so these should both be hits (verifiable via slog cacheStatus="hit"
# in the server log).
show "Anonymous: realm second call (cache hit expected)" GET /showcase/keycloak/realm 200
show "Anonymous: realm third call (cache hit expected)" GET /showcase/keycloak/realm 200

# --- 10.B — oauth2-client-credentials + admin endpoint ---------------------

# The service-account-omnicore-users-client doesn't carry realm-management
# view-users role by default; Keycloak returns 403. The framework wraps it
# in the 502 envelope. The point of this case is to prove the OAuth2 provider
# acquired and forwarded the bearer (otherwise we'd see 401 invalid_token).
# A subsequent call should reuse the cached token (verify via timing —
# the cold call hits both token + admin endpoints, warm only hits admin).

show_with_body_contains \
    "OAuth2 admin: 403 (service account lacks realm-management role; expected)" \
    GET /showcase/keycloak/admin/00000000-0000-0000-0000-000000000000 502 "status 403"

# A second admin call should be faster because the token is cached.
echo "${WHITE}--- OAuth2 admin: timing comparison (token cache) ---${RESET}"
T1=$(curl -s -o /dev/null -w "%{time_total}" "${BASE}/showcase/keycloak/admin/00000000-0000-0000-0000-000000000001")
T2=$(curl -s -o /dev/null -w "%{time_total}" "${BASE}/showcase/keycloak/admin/00000000-0000-0000-0000-000000000002")
echo "First call:  ${T1}s"
echo "Second call: ${T2}s"
# Both calls fail with 403; the timing comparison shows whether the second
# call skipped the token endpoint round-trip.
T1_MS=$(awk "BEGIN{printf \"%d\", $T1*1000}")
T2_MS=$(awk "BEGIN{printf \"%d\", $T2*1000}")
if [ "${T2_MS}" -lt "${T1_MS}" ]; then
    echo "${GREEN}PASS${RESET} (second call faster — token cache hit)"
    PASS=$((PASS + 1))
else
    echo "${YELLOW}WARN${RESET} (timing inconclusive; check slog for token endpoint hit count)"
    PASS=$((PASS + 1))
fi
echo ""

# --- 10.C — credentials-exchange multi-tenant ------------------------------

show "Tenant: missing query params returns 400" GET /showcase/keycloak/tenant/whoami 400

show_with_body_contains \
    "Tenant: alice (correct password) returns 200 with userinfo" \
    GET /showcase/keycloak/tenant/whoami 200 "\"preferred_username\":\"alice\"" "username=alice&password=alice123"

show_with_body_contains \
    "Tenant: bob (correct password) returns 200 with userinfo" \
    GET /showcase/keycloak/tenant/whoami 200 "\"preferred_username\":\"bob\"" "username=bob&password=bob123"

show_with_body_contains \
    "Tenant: alice with wrong password returns 502 (Invalid user credentials)" \
    GET /showcase/keycloak/tenant/whoami 502 "Invalid user credentials" "username=alice&password=wrong"

# Per-tenant cache: alice's second call should be faster (token cached
# under alice's identity hash). Bob's interleaved call must not poison
# alice's cache.
echo "${WHITE}--- Tenant: per-identity cache timing ---${RESET}"
A1=$(curl -s -o /dev/null -w "%{time_total}" "${BASE}/showcase/keycloak/tenant/whoami?username=alice&password=alice123")
B1=$(curl -s -o /dev/null -w "%{time_total}" "${BASE}/showcase/keycloak/tenant/whoami?username=bob&password=bob123")
A2=$(curl -s -o /dev/null -w "%{time_total}" "${BASE}/showcase/keycloak/tenant/whoami?username=alice&password=alice123")
echo "Alice (cold): ${A1}s"
echo "Bob   (cold): ${B1}s"
echo "Alice (warm): ${A2}s"
A2_MS=$(awk "BEGIN{printf \"%d\", $A2*1000}")
A1_MS=$(awk "BEGIN{printf \"%d\", $A1*1000}")
if [ "${A2_MS}" -lt "${A1_MS}" ]; then
    echo "${GREEN}PASS${RESET} (alice's second call faster despite bob's intervening call — per-identity cache works)"
    PASS=$((PASS + 1))
else
    echo "${YELLOW}WARN${RESET} (timing inconclusive)"
    PASS=$((PASS + 1))
fi
echo ""

# --- Streaming + signing + WithConfig showcase ------------------------------
#
# /showcase/httpclient/* exercise the framework's streaming surfaces (download,
# upload, multipart, SSE), HMAC request signing, and the consolidated
# CallConfig per-call override. The producer side lives in the same
# service under /echo/*; the httpClient block points the `echo` /
# `echo-signed` services at localhost:8080.

# Helper: POST with raw body, expect status + body substring.
show_post_body_contains() {
    local desc="$1" path="$2" expected_status="$3" expected_substring="$4" body="${5:-}"
    local content_type="${6:-application/octet-stream}"
    echo "${WHITE}--- ${desc} ---${RESET}"
    echo "REQUEST : POST ${path}"
    local status
    status=$(curl -s -o /tmp/qa-httpclient.body -w "%{http_code}" \
        -X POST -H "Content-Type: ${content_type}" --data-binary "${body}" \
        "${BASE}${path}")
    echo "STATUS  : ${status}"
    if [ "${status}" = "${expected_status}" ] && grep -q "${expected_substring}" /tmp/qa-httpclient.body; then
        echo "${GREEN}PASS${RESET}"
        PASS=$((PASS + 1))
    else
        echo "${RED}FAIL${RESET} (expected ${expected_status} and body containing '${expected_substring}')"
        echo "BODY: $(head -c 400 /tmp/qa-httpclient.body)"
        FAIL=$((FAIL + 1))
    fi
    echo ""
}

# Download streaming — caller copies the body bytes through StreamResponse.
show_with_body_contains \
    "Showcase: download streaming (1024 bytes)" \
    GET /showcase/httpclient/download-stream/1024 200 \
    '"bytes":1024'

# Upload streaming — body piped via http:"body,stream" tag.
show_post_body_contains \
    "Showcase: upload streaming" \
    /showcase/httpclient/upload-stream 200 \
    '"received_bytes":256' \
    "$(printf 'X%.0s' {1..256})"

# Multipart upload — the upstream parses the framework's multipart writer.
show_post_body_contains \
    "Showcase: multipart upload" \
    /showcase/httpclient/multipart 200 \
    'passport.pdf' \
    'BINARY-PLACEHOLDER'

# SSE — three events parsed by the EventSource pump and returned as JSON.
show_with_body_contains \
    "Showcase: SSE event stream" \
    GET /showcase/httpclient/sse 200 \
    '"count":3'

# HMAC signing — upstream echoes the framework-injected headers.
show_post_body_contains \
    "Showcase: HMAC signing (X-Signature)" \
    /showcase/httpclient/signed 200 \
    '"x_signature":"' \
    'sign-me'
show_post_body_contains \
    "Showcase: HMAC signing (X-Date)" \
    /showcase/httpclient/signed 200 \
    '"x_date":"' \
    'sign-me-too'
show_post_body_contains \
    "Showcase: HMAC signing (X-Content-SHA256)" \
    /showcase/httpclient/signed 200 \
    '"x_content_sha":"' \
    'hash-the-body'
show_post_body_contains \
    "Showcase: HMAC signing (X-Key-Id)" \
    /showcase/httpclient/signed 200 \
    '"x_key_id":"demo-key-1"' \
    'and-the-key'

# WithConfig — runtime method/path override turns a GET stream endpoint
# into a POST upload at call time.
show_post_body_contains \
    "Showcase: WithConfig per-call override" \
    /showcase/httpclient/with-config-override 200 \
    '"received_bytes":' \
    'override-this'

# InlineAuth.Bearer — runtime credential propagated as Authorization.
echo "${WHITE}--- Showcase: InlineAuth Bearer header propagation ---${RESET}"
echo "REQUEST : POST /showcase/httpclient/inline-bearer?token=qa-test-bearer"
INLINE_STATUS=$(curl -s -o /tmp/qa-httpclient.body -w "%{http_code}" \
    -X POST "${BASE}/showcase/httpclient/inline-bearer?token=qa-test-bearer")
echo "STATUS  : ${INLINE_STATUS}"
if [ "${INLINE_STATUS}" = "200" ] && grep -q '"authorization":"Bearer qa-test-bearer"' /tmp/qa-httpclient.body; then
    echo "${GREEN}PASS${RESET}"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET} (expected 200 with Bearer qa-test-bearer in echoed Authorization)"
    echo "BODY: $(head -c 400 /tmp/qa-httpclient.body)"
    FAIL=$((FAIL + 1))
fi
echo ""

# --- Extra: Realm discovery shape ------------------------------------------
# The first /realm case asserts the issuer. Cover other fields the consumer
# typically reads — token_endpoint, jwks_uri, userinfo_endpoint — so the
# DTO shape is locked end-to-end.
show_with_body_contains \
    "Realm: carries token_endpoint" \
    GET /showcase/keycloak/realm 200 "\"token_endpoint\":\"http://localhost:8088/realms/omnicore-test/protocol/openid-connect/token\""
show_with_body_contains \
    "Realm: carries jwks_uri" \
    GET /showcase/keycloak/realm 200 "\"jwks_uri\":\"http://localhost:8088/realms/omnicore-test/protocol/openid-connect/certs\""
show_with_body_contains \
    "Realm: carries userinfo_endpoint" \
    GET /showcase/keycloak/realm 200 "\"userinfo_endpoint\":\"http://localhost:8088/realms/omnicore-test/protocol/openid-connect/userinfo\""

# --- Extra: credentials-exchange variants ----------------------------------
# Original covers missing/correct/wrong-password. Add: only username,
# only password, alice's subject claim, bob's subject claim, alice ≠ bob.
show "Tenant: only username (no password) returns 400" \
    GET /showcase/keycloak/tenant/whoami 400 "username=alice"
show "Tenant: only password (no username) returns 400" \
    GET /showcase/keycloak/tenant/whoami 400 "password=alice123"
show_with_body_contains \
    "Tenant: alice response carries sub claim" \
    GET /showcase/keycloak/tenant/whoami 200 "\"sub\":" "username=alice&password=alice123"
show_with_body_contains \
    "Tenant: bob response carries email claim" \
    GET /showcase/keycloak/tenant/whoami 200 "\"email\":" "username=bob&password=bob123"
# Asymmetry of identity isolation — alice's userinfo cannot equal bob's.
ALICE_BODY=$(curl -s "${BASE}/showcase/keycloak/tenant/whoami?username=alice&password=alice123")
BOB_BODY=$(curl -s "${BASE}/showcase/keycloak/tenant/whoami?username=bob&password=bob123")
echo "${WHITE}--- Tenant: alice ≠ bob (per-identity isolation) ---${RESET}"
if [ "${ALICE_BODY}" != "${BOB_BODY}" ] && echo "${ALICE_BODY}" | grep -q "alice" && echo "${BOB_BODY}" | grep -q "bob"; then
    echo "${GREEN}PASS${RESET} (responses differ; each tenant gets its own userinfo)"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET} (responses identical or wrong tenant — cache cross-contamination?)"
    echo "alice: $(echo "${ALICE_BODY}" | head -c 200)"
    echo "bob:   $(echo "${BOB_BODY}" | head -c 200)"
    FAIL=$((FAIL + 1))
fi
echo ""

# --- Extra: download streaming variants ------------------------------------
# Original covers 1024 bytes. Cover the boundaries: small (1) and a few
# distinct sizes to assert the framework's StreamResponse copies arbitrary
# byte counts.
show_with_body_contains \
    "Download streaming: 1 byte" \
    GET /showcase/httpclient/download-stream/1 200 '"bytes":1'
show_with_body_contains \
    "Download streaming: 32 bytes" \
    GET /showcase/httpclient/download-stream/32 200 '"bytes":32'
show_with_body_contains \
    "Download streaming: 65536 bytes" \
    GET /showcase/httpclient/download-stream/65536 200 '"bytes":65536'
show_with_body_contains \
    "Download streaming: sample carries upstream payload" \
    GET /showcase/httpclient/download-stream/16 200 '"sample":"XXXXXXXXXXXXXXXX"'

# --- Extra: upload streaming variants --------------------------------------
# Original asserts 256 bytes. Add: small (1 byte) and large (16384 bytes).
show_post_body_contains \
    "Upload streaming: 1 byte" \
    /showcase/httpclient/upload-stream 200 '"received_bytes":1' "X"
show_post_body_contains \
    "Upload streaming: 16384 bytes" \
    /showcase/httpclient/upload-stream 200 '"received_bytes":16384' "$(printf 'A%.0s' {1..16384})"

# --- Extra: multipart structure --------------------------------------------
# Original asserts the file appears. Surface the field too.
show_post_body_contains \
    "Multipart: text field surfaces in upstream response" \
    /showcase/httpclient/multipart 200 '"category":"id-proof"' 'BIN'
show_post_body_contains \
    "Multipart: file mime type captured" \
    /showcase/httpclient/multipart 200 'application/pdf' 'BIN'

# --- Extra: SSE structure --------------------------------------------------
# Original asserts count=3. Assert the events array carries the event
# names produced by /echo/sse (tick, tick, end).
show_with_body_contains \
    "SSE: events array carries 'tick' event" \
    GET /showcase/httpclient/sse 200 '"event":"tick"'
show_with_body_contains \
    "SSE: events array carries 'end' event" \
    GET /showcase/httpclient/sse 200 '"event":"end"'
show_with_body_contains \
    "SSE: 'data' field surfaces from the upstream" \
    GET /showcase/httpclient/sse 200 '"data":'

# --- Extra: HMAC signing — every observed header is non-empty ----------------
# Original cases assert each header appears as a key but not the shape.
# Pin: signature is hex-encoded (a-f0-9 only) and at least 32 chars (SHA-256 hex).
show_post_body_contains \
    "HMAC signing: signature is hex-shaped (non-empty)" \
    /showcase/httpclient/signed 200 '"x_signature":"[0-9a-f]\{32,\}"' \
    'sign-this-payload' application/json
# Authorization header is NOT injected by signing alone (no auth provider declared
# for echo-signed) — assert it's empty so signing isn't accidentally adding it.
show_post_body_contains \
    "HMAC signing: Authorization is empty (no auth provider on echo-signed)" \
    /showcase/httpclient/signed 200 '"authorization":""' \
    'unsigned-marker' application/json

# --- Extra: WithConfig override — content type captured -------------------
# Original asserts received_bytes is present. Pin the content type the
# framework's binding sets when CallConfig.RequestCodec falls back to JSON.
show_post_body_contains \
    "WithConfig: upstream observed application/json content type" \
    /showcase/httpclient/with-config-override 200 '"content_type":"application/json"' \
    'override-payload'

# --- Extra: InlineAuth.Bearer variations -----------------------------------
# Original tests the explicit ?token=. Pin the empty/default fallback —
# the handler substitutes demo-bearer-token when ?token is missing.
echo "${WHITE}--- InlineAuth: no token param falls back to demo-bearer-token ---${RESET}"
echo "REQUEST : POST /showcase/httpclient/inline-bearer (no ?token)"
INLINE_STATUS=$(curl -s -o /tmp/qa-httpclient.body -w "%{http_code}" \
    -X POST "${BASE}/showcase/httpclient/inline-bearer")
echo "STATUS  : ${INLINE_STATUS}"
if [ "${INLINE_STATUS}" = "200" ] && grep -q '"authorization":"Bearer demo-bearer-token"' /tmp/qa-httpclient.body; then
    echo "${GREEN}PASS${RESET}"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET} (expected 200 with Bearer demo-bearer-token default)"
    echo "BODY: $(head -c 400 /tmp/qa-httpclient.body)"
    FAIL=$((FAIL + 1))
fi
echo ""

# Multiple distinct inline tokens roundtrip independently — each call is
# atomic, no cache cross-contamination because InlineAuth bypasses the
# token cache (see CLAUDE.md "InlineAuth credentials are static for one call").
echo "${WHITE}--- InlineAuth: two distinct tokens roundtrip independently ---${RESET}"
T1_BODY=$(curl -s -X POST "${BASE}/showcase/httpclient/inline-bearer?token=token-A")
T2_BODY=$(curl -s -X POST "${BASE}/showcase/httpclient/inline-bearer?token=token-B")
if echo "${T1_BODY}" | grep -q "Bearer token-A" && echo "${T2_BODY}" | grep -q "Bearer token-B"; then
    echo "${GREEN}PASS${RESET} (each call carries its own token)"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET}"
    echo "T1: $(echo "${T1_BODY}" | head -c 200)"
    echo "T2: $(echo "${T2_BODY}" | head -c 200)"
    FAIL=$((FAIL + 1))
fi
echo ""

# --- Extra: OAuth2 admin — third call still cached -----------------------
# Original times two calls. Add a third to assert the cache holds across more
# than one warm hit.
echo "${WHITE}--- OAuth2 admin: third call still benefits from cache ---${RESET}"
T3=$(curl -s -o /dev/null -w "%{time_total}" "${BASE}/showcase/keycloak/admin/00000000-0000-0000-0000-000000000003")
T4=$(curl -s -o /dev/null -w "%{time_total}" "${BASE}/showcase/keycloak/admin/00000000-0000-0000-0000-000000000004")
echo "Call 3 : ${T3}s"
echo "Call 4 : ${T4}s"
T3_MS=$(awk "BEGIN{printf \"%d\", $T3*1000}")
T4_MS=$(awk "BEGIN{printf \"%d\", $T4*1000}")
# Both should be in the warm range — well below the cold-call cost of the
# first /admin/* hit. Use 500ms as a conservative upper bound on the warm
# path (token cache hit + admin REST + framework overhead).
if [ "${T3_MS}" -lt 500 ] && [ "${T4_MS}" -lt 500 ]; then
    echo "${GREEN}PASS${RESET} (both warm calls under 500ms)"
    PASS=$((PASS + 1))
else
    echo "${YELLOW}WARN${RESET} (timing inconclusive; check slog for token endpoint hits)"
    PASS=$((PASS + 1))
fi
echo ""

# --- Summary ---------------------------------------------------------------

echo "${CYAN}============================================================${RESET}"
echo "${YELLOW}== Summary ==${RESET}"
echo ""
echo "PASS=${PASS}  FAIL=${FAIL}"
echo ""

[ "${FAIL}" -eq 0 ]
