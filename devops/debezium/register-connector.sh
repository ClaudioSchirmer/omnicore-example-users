#!/usr/bin/env bash
# Brings up the CDC relay for a QA lane. The two lanes use DIFFERENT relays:
#
#   postgres  → Debezium CONNECT (Kafka). Registered via REST (:8083): the outbox
#               connector + the qa-integration connector, both EventRouter-routed.
#   mysql     → Debezium SERVER (NATS). Static mounted config (conf-mysql-nats),
#               no REST API; "registering" = (re)creating the container and
#               waiting for it to reach streaming.
#   sqlserver → Debezium CONNECT (dedicated Kafka, REST :8085), preceded by the
#               per-table sp_cdc_enable_* step.
#   oracle    → Debezium SERVER (dedicated NATS, conf-oracle-nats), preceded by
#               the per-table supplemental-logging step.
#
# Usage: register-connector.sh [postgres|mysql|sqlserver|oracle]   (default: postgres)
#
# Run after `docker compose up` AND after the lane's app has booted once
# (migrations create the outbox/integration_events tables; the app creates the
# JetStream stream the NATS relay publishes into, and the Connect connector needs
# the tables to exist or its task lands FAILED). Idempotent for both relays.

set -euo pipefail

DIALECT="${1:-postgres}"
case "$DIALECT" in
  postgres|mysql|sqlserver|oracle) ;;
  *) echo "unknown dialect '$DIALECT' (want postgres|mysql|sqlserver|oracle)" >&2; exit 2 ;;
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

# ── Lane C (SQL Server → Kafka): Debezium Connect via REST (:8085) ──────────
# Same relay pattern as lane A, on the lane's OWN Connect. Two extra steps the
# other dialects don't have: (1) Debezium's SqlServerConnector reads CDC
# capture tables, so CDC must be enabled on the database AND on exactly the
# two tables it tails (never the domain tables) — idempotent below; requires
# SQL Server Agent (the compose profile enables it). (2) The DB may live on a
# remote docker engine (QA_SQLSERVER_CONTEXT/QA_SQLSERVER_DB_HOST) while
# Connect stays local, so the connector host/port are substituted per run.
if [ "$DIALECT" = "sqlserver" ]; then
  command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 2; }
  CONNECT_URL="${CONNECT_URL_SQLSERVER:-http://localhost:8085}"
  CTX="${QA_SQLSERVER_CONTEXT:-default}"
  SA_PW="${QA_SQLSERVER_SA_PASSWORD:-OmnicoreQA!2026}"
  if [ -n "${QA_SQLSERVER_DB_HOST:-}" ] && [ "${QA_SQLSERVER_DB_HOST}" != "127.0.0.1" ]; then
    QA_MSSQL_HOST="$QA_SQLSERVER_DB_HOST"; QA_MSSQL_PORT="14333"   # remote engine — reach over the LAN
  else
    QA_MSSQL_HOST="sqlserver"; QA_MSSQL_PORT="1433"                # same compose network
  fi

  sqlcmd_db() { docker --context "$CTX" exec omnicore-qa-sqlserver /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$SA_PW" -d users_db -h -1 -Q "$1"; }

  echo "Enabling CDC on users_db (db + outbox + integration_events; idempotent) ..."
  sqlcmd_db "IF (SELECT is_cdc_enabled FROM sys.databases WHERE name='users_db') = 0 EXEC sys.sp_cdc_enable_db" >/dev/null
  sqlcmd_db "IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name='outbox' AND is_tracked_by_cdc=1) EXEC sys.sp_cdc_enable_table @source_schema=N'dbo', @source_name=N'outbox', @role_name=NULL" >/dev/null
  sqlcmd_db "IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name='integration_events' AND is_tracked_by_cdc=1) EXEC sys.sp_cdc_enable_table @source_schema=N'dbo', @source_name=N'integration_events', @role_name=NULL" >/dev/null
  echo "CDC enabled."

  echo "Waiting for Kafka Connect at $CONNECT_URL ..."
  DEADLINE=$(( $(date +%s) + 120 ))
  until curl -sf "$CONNECT_URL/" >/dev/null 2>&1; do
    [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "ERROR: Kafka Connect (sqlserver) not up after 120s" >&2; exit 1; }
    sleep 2
  done

  for f in users-outbox-sqlserver-connector.json qa-integration-sqlserver-connector.json; do
    NAME=$(jq -r .name "$HERE/$f")
    BODY=$(sed -e "s/\${QA_MSSQL_HOST}/$QA_MSSQL_HOST/g" -e "s/\${QA_MSSQL_PORT}/$QA_MSSQL_PORT/g" "$HERE/$f")
    echo "Registering $NAME ..."
    printf '%s' "$BODY" | jq .config | curl -sf -X PUT -H "Content-Type: application/json" -d @- "$CONNECT_URL/connectors/$NAME/config" >/dev/null \
      || { echo "ERROR: registering $NAME failed" >&2; exit 1; }
    DEADLINE=$(( $(date +%s) + 120 ))
    while :; do
      STATE=$(curl -sf "$CONNECT_URL/connectors/$NAME/status" | jq -r '.tasks[0].state' 2>/dev/null)
      [ "$STATE" = "RUNNING" ] && break
      # A config PUT does NOT revive a FAILED task (e.g. the task tried to
      # start while the DB container was still booting after a recreate and
      # Connect never retries on its own) — restart it explicitly.
      [ "$STATE" = "FAILED" ] && curl -s -X POST "$CONNECT_URL/connectors/$NAME/tasks/0/restart" >/dev/null
      [ "$(date +%s)" -ge "$DEADLINE" ] && { echo "ERROR: $NAME task not RUNNING in 120s" >&2; curl -s "$CONNECT_URL/connectors/$NAME/status" | jq . >&2; exit 1; }
      sleep 2
    done
    echo "$NAME RUNNING."
  done
  echo "Debezium Connect streaming (sqlserver → Kafka)."
  exit 0
fi

# ── Lane D (Oracle → NATS): static Debezium Server ──────────────────────────
# Same relay pattern as lane B (static mounted config, conf-oracle-nats, no
# REST), preceded by the Oracle twin of lane C's CDC-enable step: PER-TABLE
# SUPPLEMENTAL LOGGING (ALL COLUMNS) on exactly the two tables the connector
# tails — the database-level pieces (ARCHIVELOG, minimal supplemental logging,
# the c##dbzuser LogMiner user, the debezium_heartbeat table) were provisioned
# once by devops/oracle/init/02_cdc.sh at first boot. The DB may live on a
# remote docker engine (QA_ORACLE_CONTEXT) while the relay stays local.
if [ "$DIALECT" = "oracle" ]; then
  COMPOSE_FILE="$(cd "$HERE/.." && pwd)/docker-compose.yml"
  CONTAINER="omnicore-qa-debezium-oracle"
  CTX="${QA_ORACLE_CONTEXT:-default}"
  APP_PW="${QA_ORACLE_APP_PASSWORD:-omnicore}"

  sqlplus_app() { # one statement, app schema, clean single-value output
    printf 'SET PAGESIZE 0 FEEDBACK OFF HEADING OFF VERIFY OFF\n%s\n' "$1" \
      | docker --context "$CTX" exec -i omnicore-qa-oracle sqlplus -S "omnicore/${APP_PW}@localhost/FREEPDB1" \
      | tr -d ' \t\r'
  }

  echo "Enabling per-table supplemental logging (outbox + integration_events; idempotent) ..."
  for T in OUTBOX INTEGRATION_EVENTS; do
    HAS=$(sqlplus_app "SELECT COUNT(*) FROM user_log_groups WHERE table_name='$T' AND log_group_type='ALL COLUMN LOGGING';")
    if [ "${HAS:-0}" = "0" ]; then
      sqlplus_app "ALTER TABLE $T ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;" >/dev/null
      echo "  $T: supplemental logging (ALL) COLUMNS added"
    else
      echo "  $T: already enabled"
    fi
  done

  # The LogMiner heartbeat (SCN advancement, heartbeat.action.query) is also
  # PUBLISHED by the sink — to __debezium-heartbeat.<topic.prefix>, a subject
  # no stream covers (the app's OMNICORE_EVENTS is omnicore.> only, and
  # create-stream=false by design). Without a stream the JetStream publish
  # gets "503 No Responders" and the connector dies, so give the heartbeats
  # their own tiny stream (idempotent; keeps ONE message, memory-only).
  echo "Ensuring the DEBEZIUM_HEARTBEAT stream exists on nats-oracle ..."
  docker run --rm --network omnicore-qa_default natsio/nats-box:latest \
    sh -c "nats -s nats://nats-oracle:4222 stream info DEBEZIUM_HEARTBEAT >/dev/null 2>&1 \
      || nats -s nats://nats-oracle:4222 stream add DEBEZIUM_HEARTBEAT \
           --subjects '__debezium-heartbeat.>' --storage memory --retention limits \
           --max-msgs 1 --discard old --defaults >/dev/null"

  echo "Recreating Debezium Server (oracle → NATS) ..."
  docker compose -f "$COMPOSE_FILE" --profile oracle up -d --force-recreate debezium-server-oracle

  echo "Waiting for Debezium Server (oracle) to start streaming ..."
  DEADLINE=$(( $(date +%s) + 180 ))
  until docker logs "$CONTAINER" 2>&1 | grep -q "Starting streaming"; do
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
      echo "ERROR: Debezium Server (oracle) did not reach streaming in 180s — boot the oracle app once (so the outbox table + JetStream stream exist), then re-run." >&2
      docker logs "$CONTAINER" 2>&1 | tail -25 >&2
      exit 1
    fi
    sleep 2
  done
  echo "Debezium Server streaming (oracle → NATS)."
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
    # A config PUT does NOT revive a FAILED task (Connect never retries a task
    # that failed at start, e.g. against a still-booting DB) — restart it.
    if [ "$(curl -sf "$CONNECT_URL/connectors/$name/status" 2>/dev/null | jq -r '.tasks[0].state' 2>/dev/null)" = "FAILED" ]; then
      curl -s -X POST "$CONNECT_URL/connectors/$name/tasks/0/restart" >/dev/null
    fi
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
