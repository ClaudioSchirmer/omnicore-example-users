#!/usr/bin/env bash
# Registers the Debezium outbox connector against the running Kafka Connect
# instance. Run this once after `docker compose up` is healthy.
#
# Usage: register-connector.sh [postgres|mysql]   (default: postgres)
#   postgres -> users-outbox-connector.json       (tails public.outbox via pgoutput)
#   mysql    -> users-outbox-connector-mysql.json  (tails users_db.outbox via binlog)
#
# Both connectors route to the SAME topic (users.events) via the outbox
# EventRouter, so the service's SyncEngine consumes whichever backend is active.
# Register only the connector matching the backend you are running; the QA model
# runs one backend at a time. The connectors carry distinct names + topic
# prefixes, so registering one never disturbs the other.
#
# Idempotent: if a connector with the same name already exists, it is updated
# in place via PUT /config rather than POST /connectors.

set -euo pipefail

DIALECT="${1:-postgres}"
case "$DIALECT" in
  postgres) CONFIG_BASENAME="users-outbox-connector.json" ;;
  mysql)    CONFIG_BASENAME="users-outbox-connector-mysql.json" ;;
  *) echo "unknown dialect '$DIALECT' (want postgres|mysql)" >&2; exit 2 ;;
esac

CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
CONFIG_FILE="$(dirname "$0")/$CONFIG_BASENAME"
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
