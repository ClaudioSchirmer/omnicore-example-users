#!/usr/bin/env bash
# Registers the Debezium connector against the running Kafka Connect instance.
# Run this once after `docker compose up` is healthy.
#
# Idempotent: if a connector with the same name already exists, it is updated
# in place via PUT /config rather than POST /connectors.

set -euo pipefail

CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
CONFIG_FILE="$(dirname "$0")/users-outbox-connector.json"
CONNECTOR_NAME=$(jq -r '.name' "$CONFIG_FILE")

echo "Waiting for Kafka Connect at $CONNECT_URL ..."
until curl -sf "$CONNECT_URL/" >/dev/null; do
  sleep 1
done
echo "Kafka Connect is up."

if curl -sf "$CONNECT_URL/connectors/$CONNECTOR_NAME" >/dev/null 2>&1; then
  echo "Connector '$CONNECTOR_NAME' exists — updating config..."
  jq '.config' "$CONFIG_FILE" \
    | curl -sf -X PUT \
        -H "Content-Type: application/json" \
        -d @- \
        "$CONNECT_URL/connectors/$CONNECTOR_NAME/config" \
    | jq .
else
  echo "Registering connector '$CONNECTOR_NAME'..."
  curl -sf -X POST \
      -H "Content-Type: application/json" \
      -d @"$CONFIG_FILE" \
      "$CONNECT_URL/connectors" \
    | jq .
fi

echo
echo "Status:"
curl -sf "$CONNECT_URL/connectors/$CONNECTOR_NAME/status" | jq .
