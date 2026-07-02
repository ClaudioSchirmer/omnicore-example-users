#!/usr/bin/env bash
# Registers the Debezium outbox connector against the running Kafka Connect
# instance. Run this once after `docker compose up` is healthy.
#
# Usage: register-connector.sh [postgres|mysql]   (default: postgres)
#   postgres -> users-outbox-connector.json       (tails public.outbox via pgoutput)
#   mysql    -> users-outbox-connector-mysql.json  (tails users_db.outbox via binlog)
#
# Both connectors route by the outbox `aggregate_type` field via the EventRouter
# (route.topic.replacement = ${routedByValue}.events), so each aggregate gets its
# own topic: the users role -> users.events, and the shared Person base ->
# persons.events (a base write emits an extra aggregate_type=persons outbox row,
# which the SyncEngine subscribes to and fans out to recompose the user docs). The
# SyncEngine creates the topics it subscribes to, so persons.events appears on its
# own. Register only the connector matching the backend you are running; the QA model
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

# On a VIRGIN volume the outbox table only exists after the app's first boot
# (migrations run at boot). Registering before that leaves the connector task
# FAILED ("No table filters found for filtered publication" on PG), with an
# empty read side and zero errors on the app — so wait for the table first.
echo "Waiting for the outbox table in the $DIALECT backend (boot the app once if this hangs) ..."
outbox_exists() {
  case "$DIALECT" in
    postgres) docker exec omnicore-example-postgres psql -U omnicore -d users_db -tA                 -c "SELECT 1 FROM information_schema.tables WHERE table_name='outbox' LIMIT 1" 2>/dev/null | grep -q 1 ;;
    mysql)    docker exec omnicore-example-mysql mysql -uomnicore -pomnicore -D users_db -N -B                 -e "SELECT 1 FROM information_schema.tables WHERE table_schema='users_db' AND table_name='outbox' LIMIT 1" 2>/dev/null | grep -q 1 ;;
  esac
}
DEADLINE=$(( $(date +%s) + 120 ))
until outbox_exists; do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "ERROR: outbox table not found in $DIALECT after 120s — start the app once (APP_PROFILE=dev go run -tags $DIALECT ./bootstrap) so migrations create it, then re-run this script." >&2
    exit 1
  fi
  sleep 2
done
echo "Outbox table present."

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
