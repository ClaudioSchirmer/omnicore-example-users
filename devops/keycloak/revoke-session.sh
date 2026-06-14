#!/usr/bin/env bash
# Revokes a Keycloak access token via the RFC 7009 token revocation endpoint
# so subsequent introspection reports active=false. Used by qa/auth.sh to
# exercise the external-validator revocation path: a JWT whose local signature
# still validates is rejected because the IdP says it is no longer active.
#
# Why not logout-via-refresh: the realm's logout endpoint kills the session
# (refresh_token can no longer mint new tokens) but the access_token introspect
# may still report active=true during its remaining lifespan. RFC 7009 /revoke
# blacklists the specific access_token, which is exactly what the framework's
# external validator checks.
#
# Usage:
#   token=$(./mint-token.sh alice)
#   ./revoke-session.sh "$token"

set -eu

KC_URL="${KC_URL:-http://localhost:8088}"
REALM="${REALM:-omnicore-test}"
CLIENT_ID="${CLIENT_ID:-omnicore-users-client}"
CLIENT_SECRET="${CLIENT_SECRET:-test-secret-please-change}"

token="${1:-}"
if [ -z "$token" ]; then
  echo "usage: $(basename "$0") <access_token>" >&2
  exit 2
fi

curl -sf -o /dev/null -X POST "${KC_URL}/realms/${REALM}/protocol/openid-connect/revoke" \
  -u "${CLIENT_ID}:${CLIENT_SECRET}" \
  -d "token=${token}" \
  -d "token_type_hint=access_token"

echo "Access token revoked."
