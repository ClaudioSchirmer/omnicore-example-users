#!/usr/bin/env bash
# Blocks until the Keycloak realm `omnicore-test` is reachable and exporting
# its public key. Used by qa/auth.sh before minting tokens.
#
# Usage: ./wait-ready.sh [timeout_seconds]

set -u

KC_URL="${KC_URL:-http://localhost:8088}"
REALM="${REALM:-omnicore-test}"
TIMEOUT="${1:-90}"

deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if curl -sf "${KC_URL}/realms/${REALM}" | grep -q '"public_key"'; then
    echo "Keycloak realm '${REALM}' is ready at ${KC_URL}"
    exit 0
  fi
  sleep 2
done

echo "TIMEOUT (${TIMEOUT}s) waiting for Keycloak at ${KC_URL}/realms/${REALM}" >&2
exit 1
