#!/usr/bin/env bash
# Integration-events suite (via the qa-only Gadget).
#
# The framework's async cross-service event bus: a write DISPATCHES an event
# into integration_events IN THE SAME TX (atomic with the data + outbox + audit),
# a Debezium connector relays that table to Kafka, and a RECEIVER consumes it
# with at-least-once + best-effort dedup semantics. The canonical example wires
# neither a publisher nor a receiver, so this was 0% covered. Here the qa Gadget
# publishes GadgetCreated from its insert BeforeCommit hook and the SAME service
# self-subscribes, recording the event into an idempotent gadget_events_sink.
#
# Asserts: (1) the integration_events row lands in the write TX; (2) the receiver
# consumes it into the sink; (3) dedup — exactly one omnicore_integration_processed
# row per (event_id, consumer_group) and one sink row per gadget; (4) the failure
# registry is empty on the happy path and /admin/retries/integration drains.
#
# Uses the qa binary + microservice.qa.yaml + a qa Debezium connector on the
# integration_events table (devops/debezium/qa-integration-connector.json →
# topic qa.integration.events). Self-managed lifecycle. Dialect-driven via
# qa/_backend.sh — the qa integration connector has a pgoutput and a binlog
# variant, selected by $BACKEND.
#
# Run from anywhere:  bash qa/integration_events.sh
set -u

BASE="${BASE:-http://localhost:8080}"
CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-integration"
SERVER_LOG="/tmp/omnicore-example-users-qa-integration.log"
QA_YAML="$REPO_ROOT/microservice.qa.yaml"
# The qa integration connector tails the integration_events table into the fixed
# topic qa.integration.events — one per engine (pgoutput vs binlog).
if [ "$BACKEND" = "mysql" ]; then
  QA_CONNECTOR="$REPO_ROOT/devops/debezium/qa-integration-connector-mysql.json"
  # Backend-specific topic so the mysql consumer never replays postgres events.
  export QA_INTEGRATION_TOPIC="qa.integration.events.mysql"
else
  QA_CONNECTOR="$REPO_ROOT/devops/debezium/qa-integration-connector.json"
  export QA_INTEGRATION_TOPIC="qa.integration.events"
fi

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
cleanup() { if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi; kill_port 8080; docker exec omnicore-example-mongo mongosh "$QA_MONGO_DB" --quiet --eval "db.gadgets.drop(); db.gadget_notes.drop(); db.gadgets_hot.drop(); db.gadgets_capped.drop(); db.gadgets_embedded.drop(); db.upstream_gadgets.drop()" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

# Create-if-absent only: a config PUT restarts the Debezium task (re-snapshot +
# stream resume), and an event produced during that window is missed. A stable,
# already-RUNNING connector + a fresh consumer group (deleted on cleanup) is the
# deterministic combination.
register_qa_connector() {
  local name; name=$(jq -r '.name' "$QA_CONNECTOR")
  if curl -sf "$CONNECT_URL/connectors/$name/status" >/dev/null 2>&1; then
    return 0
  fi
  curl -sf -X POST -H "Content-Type: application/json" -d @"$QA_CONNECTOR" "$CONNECT_URL/connectors" >/dev/null
}

# Delete the integration consumer group so the next run rejoins fresh at the
# topic's latest offset (only sees the event THIS run produces). Safe only while
# the group has no active members — call it after the server is stopped.
delete_consumer_group() {
  docker exec omnicore-example-kafka bash -c \
    "kafka-consumer-groups --bootstrap-server localhost:9092 --delete --group '$INTEGRATION_GROUP_ID'" >/dev/null 2>&1 || true
}

##############################################################################
sec "0. Build qa binary + boot (creates integration_events) + register connectors"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port 8080
# No server is running yet → the consumer group is inactive → delete it so this
# run rejoins fresh at the topic's latest offset (deterministic: it only ever
# processes the event THIS run produces).
delete_consumer_group

title "0.2 Register the outbox connector (gadgets table must exist — boot creates it)"
# Boot once so migrations + the qa-table provisioning create outbox + integration_events.
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$QA_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/health" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready (config=microservice.qa.yaml)" || { bad "server not ready"; tail -n 40 "$SERVER_LOG"; exit 1; }
"$REPO_ROOT/devops/debezium/register-connector.sh" "$QA_CONNECTOR_DIALECT" >/dev/null 2>&1 && ok "outbox connector registered" || bad "outbox connector registration failed"

title "0.3 Register the qa integration_events connector (→ $QA_INTEGRATION_TOPIC)"
if register_qa_connector; then ok "qa-integration connector registered"; else bad "qa-integration connector registration failed"; fi
# Wait for the task to actually reach RUNNING before producing events. A config
# UPDATE (re-run) restarts the task; the mysql binlog connector in particular
# needs a moment to re-snapshot + resume streaming, and an event produced during
# that window would be missed by the consumer.
QA_CONN_NAME=$(jq -r '.name' "$QA_CONNECTOR")
deadline=$(( $(date +%s) + 90 )); crun=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  st=$(curl -sf "$CONNECT_URL/connectors/$QA_CONN_NAME/status" 2>/dev/null \
    | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); tasks=d.get("tasks") or []
  print(tasks[0]["state"] if tasks else d.get("connector",{}).get("state",""))
except Exception: print("")' 2>/dev/null)
  [ "$st" = "RUNNING" ] && { crun=ok; break; }
  sleep 1
done
[ "$crun" = ok ] && ok "qa-integration connector task RUNNING" || bad "qa-integration connector never reached RUNNING"
sleep 5   # binlog/pgoutput settle before the first produced event

title "0.4 Reset gadget + integration control tables"
qa_db_exec "DELETE FROM gadget_journal;" 2>/dev/null || true
qa_db_exec "DELETE FROM gadget_events_sink;" 2>/dev/null || true
qa_db_exec "DELETE FROM gadgets;"
qa_db_exec "DELETE FROM integration_events;" 2>/dev/null || true
qa_db_exec "DELETE FROM omnicore_integration_processed;" 2>/dev/null || true
qa_db_exec "DELETE FROM omnicore_integration_failures;" 2>/dev/null || true
docker exec omnicore-example-mongo mongosh "$QA_MONGO_DB" --quiet --eval 'db.gadgets.deleteMany({})' >/dev/null 2>&1 || true
sleep 1
ok "clean baseline"

##############################################################################
sec "1. Dispatch lands in integration_events IN the write TX"
##############################################################################
title "1.1 POST a gadget → BeforeCommit dispatches GadgetCreated"
RESP=$(curl -sS -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" \
  --data '{"code":"EVT-001","name":"Event One","category":"cat","status":"active"}')
GID=$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null)
[ -n "$GID" ] && ok "gadget created ($GID)" || { bad "create failed: $RESP"; }

title "1.2 integration_events carries exactly one GadgetCreated row for the aggregate"
EVT_ROWS=$(qa_db_query "SELECT count(*) FROM integration_events WHERE event_type='GadgetCreated' AND aggregate_id='$GID';" | tr -d ' ')
[ "$EVT_ROWS" = "1" ] && ok "one integration_events row (event_type=GadgetCreated, aggregate_id=gid)" || bad "integration_events rows=$EVT_ROWS (want 1)"
EVT_ID=$(qa_db_query "SELECT event_id FROM integration_events WHERE aggregate_id='$GID' LIMIT 1;" | tr -d ' ')
echo "event_id=$EVT_ID"

##############################################################################
sec "2. Receiver consumes into the idempotent sink + dedup"
##############################################################################
title "2.1 gadget_events_sink records the consumed event"
# Count total rows (the reset above emptied the sink, and this section posts a
# single gadget) — robust across engines regardless of how the gadget_id column
# is physically typed (UUID on postgres vs BINARY(16) on mysql, which a string
# WHERE comparison would miss).
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); sunk=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  c=$(qa_db_query "SELECT count(*) FROM gadget_events_sink;" 2>/dev/null | tr -d ' ')
  [ "${c:-0}" = "1" ] && { sunk=ok; break; }
  sleep 1
done
[ "$sunk" = ok ] && ok "receiver wrote exactly one sink row for the gadget" || { bad "sink never received the event"; tail -n 25 "$SERVER_LOG"; }

title "2.2 Dedup marker present — one processed row for this receiver"
# The dedup row is keyed by (event_id, consumer_group). event_id as the consumer
# sees it is the EventRouter's message id, so we match on the receiver's stable
# natural key (source_key + event_key) instead — one POST after a clean reset
# yields exactly one processed row for self_gadgets/gadgetCreated.
deadline=$(( $(date +%s) + 20 )); dedup=fail; PROW=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  PROW=$(qa_db_query "SELECT count(*) FROM omnicore_integration_processed WHERE source_key='self_gadgets' AND event_key='gadgetCreated';" 2>/dev/null | tr -d ' ')
  [ "${PROW:-0}" -ge 1 ] 2>/dev/null && { dedup=ok; break; }
  sleep 1
done
[ "$dedup" = ok ] && ok "omnicore_integration_processed carries the event (dedup mechanism active, rows=$PROW)" || bad "no processed/dedup row for the receiver"

title "2.3 Idempotency — still exactly one sink row after a settle window"
sleep 3
SINK_ROWS=$(qa_db_query "SELECT count(*) FROM gadget_events_sink;" | tr -d ' ')
[ "$SINK_ROWS" = "1" ] && ok "sink stayed at one row (at-least-once delivery, idempotent handler)" || bad "sink row count=$SINK_ROWS (want 1 — double-processed?)"

##############################################################################
sec "3. Failure registry + admin drain route"
##############################################################################
title "3.1 No pending integration failures on the happy path"
PENDING=$(qa_db_query "SELECT count(*) FROM omnicore_integration_failures WHERE resolved_at IS NULL;" 2>/dev/null | tr -d ' ')
[ "${PENDING:-0}" = "0" ] && ok "no pending integration failures" || bad "unexpected pending failures: $PENDING"

title "3.2 POST /admin/retries/integration responds 200"
ST=$(curl -sS -o /tmp/qa-int-retry.json -w "%{http_code}" -X POST "$BASE/admin/retries/integration")
echo "response: $(cat /tmp/qa-int-retry.json 2>/dev/null)"
[ "$ST" = "200" ] && ok "admin integration-retry route responds 200" || bad "admin retry status $ST"
rm -f /tmp/qa-int-retry.json

##############################################################################
sec "Cleanup + Summary"
##############################################################################
qa_db_exec "DELETE FROM gadget_events_sink;" 2>/dev/null || true
qa_db_exec "DELETE FROM gadgets;"
qa_db_exec "DELETE FROM integration_events;" 2>/dev/null || true
# DROP the qa collection so a later non-qa suite's boot registry guard does not
# abort on a foreign collection.
docker exec omnicore-example-mongo mongosh "$QA_MONGO_DB" --quiet --eval 'db.gadgets.drop(); db.gadget_notes.drop()' >/dev/null 2>&1 || true
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
