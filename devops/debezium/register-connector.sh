#!/usr/bin/env bash
# Brings up the CDC relay for a QA lane. The two lanes use DIFFERENT relays:
#
#   postgres → Debezium CONNECT (Kafka). Registered via REST (:8083): the outbox
#              connector + the qa-integration connector, both EventRouter-routed.
#   mysql    → Debezium SERVER (NATS). Static mounted config (conf-mysql-nats),
#              no REST API; "registering" = (re)creating the container and waiting
#              for it to reach streaming.
#
# Usage: register-connector.sh [postgres|mysql]   (default: postgres)
#
# Run after `docker compose up` AND after the lane's app has booted once
# (migrations create the outbox/integration_events tables; the app creates the
# JetStream stream the NATS relay publishes into, and the Connect connector needs
# the tables to exist or its task lands FAILED). Idempotent for both relays.

set -euo pipefail

DIALECT="${1:-postgres}"
case "$DIALECT" in
  postgres|mysql) ;;
  *) echo "unknown dialect '$DIALECT' (want postgres|mysql)" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"

# ── Lane B (MySQL → NATS): static Debezium Server ────────────────────────────
if [ "$DIALECT" = "mysql" ]; then
  COMPOSE_FILE="$(cd "$HERE/.." && pwd)/docker-compose.yml"
  CONTAINER="omnicore-qa-debezium"

  echo "Recreating Debezium Server (mysql → NATS) ..."
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate debezium-server

  echo "Waiting for Debezium Server to start streaming ..."
  DEADLINE=$(( $(date +%s) + 120 ))
  until docker logs "$CONTAINER" 2>&1 | grep -q "Starting streaming"; do
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
      echo "ERROR: Debezium Server did not reach streaming in 120s — boot the mysql app once (so the outbox table + JetStream stream exist), then re-run." >&2
      docker logs "$CONTAINER" 2>&1 | tail -25 >&2
      exit 1
    fi
    sleep 2
  done
  echo "Debezium Server streaming (mysql → NATS)."
  exit 0
fi

# ── Lane A (Postgres → Kafka): Debezium Connect via REST ─────────────────────
CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
DB_CONTAINER="omnicore-qa-postgres"
CONNECTORS="users-outbox-connector.json qa-integration-connector.json"

command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 2; }

echo "Waiting for Kafka Connect at $CONNECT_URL ..."
DEADLINE=$(( $(date +%s) + 120 ))
until curl -sf "$CONNECT_URL/" >/dev/null 2>&1; do
  [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "ERROR: Kafka Connect not up after 120s" >&2; exit 1; }
  sleep 2
done
echo "Kafka Connect is up."

# On a virgin volume the outbox + integration_events tables only exist after the
# app's first boot (migrations). Registering before that leaves the task FAILED
# ("No table filters found for filtered publication"), so wait for the tables.
echo "Waiting for the outbox + integration_events tables (boot the postgres app once if this hangs) ..."
tables_exist() {
  docker exec "$DB_CONTAINER" psql -U omnicore -d users_db -tA \
    -c "SELECT count(*) FROM information_schema.tables WHERE table_name IN ('outbox','integration_events')" \
    2>/dev/null | grep -q 2
}
DEADLINE=$(( $(date +%s) + 120 ))
until tables_exist; do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "ERROR: outbox/integration_events tables not found after 120s — boot the postgres app once (so migrations create them), then re-run." >&2
    exit 1
  fi
  sleep 2
done
echo "Tables present."

for cfg in $CONNECTORS; do
  file="$HERE/$cfg"
  name=$(jq -r '.name' "$file")
  if curl -sf "$CONNECT_URL/connectors/$name" >/dev/null 2>&1; then
    echo "Connector '$name' exists — updating config ..."
    jq '.config' "$file" | curl -sf -X PUT -H "Content-Type: application/json" -d @- \
      "$CONNECT_URL/connectors/$name/config" >/dev/null
  else
    echo "Registering connector '$name' ..."
    curl -sf -X POST -H "Content-Type: application/json" -d @"$file" \
      "$CONNECT_URL/connectors" >/dev/null
  fi
done

# Wait for every connector + its task to reach RUNNING — a registered-but-FAILED
# task would silently starve the read side.
echo "Waiting for connectors to reach RUNNING ..."
DEADLINE=$(( $(date +%s) + 90 ))
for cfg in $CONNECTORS; do
  name=$(jq -r '.name' "$HERE/$cfg")
  until [ "$(curl -sf "$CONNECT_URL/connectors/$name/status" 2>/dev/null | jq -r '[.connector.state, (.tasks[]?.state)] | all(. == "RUNNING")' 2>/dev/null)" = "true" ]; do
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
      echo "ERROR: connector '$name' not RUNNING in time:" >&2
      curl -sf "$CONNECT_URL/connectors/$name/status" 2>/dev/null | jq . >&2 || true
      exit 1
    fi
    sleep 2
  done
  echo "  $name: RUNNING"
done
echo "Debezium Connect streaming (postgres → Kafka)."
