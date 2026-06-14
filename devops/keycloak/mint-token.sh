#!/usr/bin/env bash
# Mints an access token from the Keycloak test realm and prints it on stdout.
#
# Subjects:
#   alice           — password grant against omnicore-users-client (audience = omnicore-users-api)
#                     permissions claim: [users:read, users:write, users:archive]
#   bob             — password grant against omnicore-users-client
#                     permissions claim: [*:*] (super admin — Layer-2 bypass)
#   noperm          — password grant; no permissions claim emitted (no attribute set)
#   client          — client_credentials grant against omnicore-users-client (no human subject)
#   wrong-aud       — client_credentials grant against wrong-aud-client (audience = some-other-service)
#
# Extras:
#   --refresh       — print the refresh_token instead of the access_token (used by revoke-session.sh)
#   --raw           — print the full token endpoint JSON response
#
# Usage:
#   ./mint-token.sh alice
#   ./mint-token.sh client
#   ./mint-token.sh alice --refresh
#   ./mint-token.sh alice --raw

set -eu

KC_URL="${KC_URL:-http://localhost:8088}"
REALM="${REALM:-omnicore-test}"
CLIENT_ID="${CLIENT_ID:-omnicore-users-client}"
CLIENT_SECRET="${CLIENT_SECRET:-test-secret-please-change}"
WRONG_CLIENT_ID="${WRONG_CLIENT_ID:-wrong-aud-client}"
WRONG_CLIENT_SECRET="${WRONG_CLIENT_SECRET:-wrong-aud-secret}"

subject="${1:-}"
flag="${2:-}"

if [ -z "$subject" ]; then
  echo "usage: $(basename "$0") <alice|bob|noperm|client|wrong-aud> [--refresh|--raw]" >&2
  exit 2
fi

token_url="${KC_URL}/realms/${REALM}/protocol/openid-connect/token"

case "$subject" in
  alice|bob|noperm)
    response=$(curl -sf -X POST "$token_url" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=password" \
      -d "client_id=${CLIENT_ID}" \
      -d "client_secret=${CLIENT_SECRET}" \
      -d "username=${subject}" \
      -d "password=${subject}123" \
      -d "scope=openid")
    ;;
  client)
    response=$(curl -sf -X POST "$token_url" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=client_credentials" \
      -d "client_id=${CLIENT_ID}" \
      -d "client_secret=${CLIENT_SECRET}")
    ;;
  wrong-aud)
    response=$(curl -sf -X POST "$token_url" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=client_credentials" \
      -d "client_id=${WRONG_CLIENT_ID}" \
      -d "client_secret=${WRONG_CLIENT_SECRET}")
    ;;
  *)
    echo "unknown subject: $subject" >&2
    exit 2
    ;;
esac

case "$flag" in
  --refresh)
    echo "$response" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("refresh_token",""))'
    ;;
  --raw)
    echo "$response"
    ;;
  "")
    echo "$response" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("access_token",""))'
    ;;
  *)
    echo "unknown flag: $flag" >&2
    exit 2
    ;;
esac
