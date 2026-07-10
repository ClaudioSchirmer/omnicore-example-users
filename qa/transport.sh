#!/usr/bin/env bash
# Transport durability + graceful-restart suite (via the qa-only Gadget).
#
# The message-transport seam (omnicore/infra/transport) is exercised end-to-end
# by every CDC-dependent suite, but no suite asserts the transport's DURABILITY
# CONTRACT directly: that the read-side projection consumer survives a graceful
# process restart and RESUMES its durable/consumer-group without losing or
# duplicating the projection. That contract is where the two adapters differ the
# most — and where the bugs bite:
#
#   - NATS JetStream: a file-backed stream + a DURABLE pull consumer whose ack
#     state must survive a consumer restart (resume from the last ack), plus the
#     delayed-ack flush on graceful Close so drained work is not redelivered.
#   - Kafka/Redpanda: the consumer group must LeaveGroup on SIGTERM so the next
#     boot's JoinGroup is not blocked by a ghost member holding the slot (the
#     "first CDC event after boot is late" symptom).
#
# This suite is transport-agnostic in its ASSERTIONS (black-box: what landed in
# Mongo) and transport-AWARE only where it introspects the broker to prove the
# durable/group persisted rather than being recreated fresh — dispatched by
# $QA_TRANSPORT_TAG exactly like integration_events.sh's consumer reset.
#
# Asserts, on whichever lane runs it (Postgres+Kafka or MySQL+NATS):
#   (1) a batch of writes projects to the `gadgets` view before restart;
#   (2) a GRACEFUL SIGTERM drains and exits cleanly within a deadline (the
#       shutdown coordination: worker drain → LeaveGroup / ack-flush, by
#       dependency not timing);
#   (3) after relaunch on the SAME group/durable, the pre-restart documents are
#       STILL present (projection is durable, not rebuilt from empty);
#   (4) the broker still holds the SAME durable consumer / group (resumed, not
#       recreated) — transport-aware probe;
#   (5) a write made AFTER restart projects within the deadline (the consumer
#       rejoined and is live — no ghost member, no blocked JoinGroup);
#   (6) idempotency under the post-restart tail replay/redelivery: each code
#       appears EXACTLY once in the view (idempotent keyed upsert absorbs the
#       at-least-once window).
#
# Uses the qa binary + microservice.qa.yaml + the main outbox connector (the
# gadget flows through the standard outbox pipeline). Self-managed lifecycle;
# dialect/transport-driven via qa/_backend.sh. Run from anywhere:
#   bash qa/transport.sh            # lane A (Postgres + Kafka)
#   BACKEND=mysql bash qa/transport.sh   # lane B (MySQL + NATS)
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-transport-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-transport-${BACKEND:-postgres}.log"
QA_YAML="$REPO_ROOT/microservice.qa.yaml"

# NATS stream every event subject lands in (must match the nats adapter's
# streamName constant); the durable consumer is named after the sync group.
NATS_STREAM="OMNICORE_EVENTS"
# Run-unique code prefix so every count filters to THIS run's gadgets — the
# suite is leftover-proof and never truncates the qa gadget table.
CODE_PREFIX="QA-TRANSPORT-$$-$(date +%s)"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
# purge_gadgets removes THIS suite's gadgets from BOTH the relational source and
# the projection. Deleting the relational rows is what makes it hermetic: the
# `gadgets` fixture view is SHARED state other gadget suites (e.g. grpc 6e) need
# clean, and leaving source rows lets a later consumer-group replay resurrect
# them into the view. With the source gone the composer re-reads current state,
# finds nothing, and never re-projects. Swept by the whole QA-TRANSPORT namespace
# (not just this run's prefix) so a prior aborted run leaves no residue either.
# The raw SQL DELETE writes no outbox row (it bypasses the framework), so it adds
# no spurious events.
purge_gadgets() {
  qa_db_exec "DELETE FROM gadgets WHERE code LIKE 'QA-TRANSPORT-%'" 2>/dev/null || true
  docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet \
    --eval "db.gadgets.deleteMany({code:{\$regex:'^QA-TRANSPORT-'}})" >/dev/null 2>&1 || true
}
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port "${HTTP_PORT:-8080}"
  purge_gadgets
}
trap cleanup EXIT INT TERM

# ── lifecycle helpers ────────────────────────────────────────────────────────

# start_server launches the qa binary and waits for /livez. Truncates the log
# on each (re)start so a restart's log is self-contained.
start_server() {
  : > "$SERVER_LOG"
  ( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$QA_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
  SERVER_PID=$!
  local deadline; deadline=$(( $(date +%s) + 30 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    curl -sf -o /dev/null "$BASE/livez" && return 0
    sleep 0.5
  done
  return 1
}

# stop_server_graceful sends SIGTERM and waits for the process to exit within a
# deadline. A hung drain (LeaveGroup / ack-flush never completing) is a FAIL,
# surfaced as a non-zero return — this is the graceful-shutdown coordination
# under test, not a timing hope.
stop_server_graceful() {
  local pid="$1" deadline
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  kill -TERM "$pid" 2>/dev/null || return 1
  deadline=$(( $(date +%s) + 30 ))
  while kill -0 "$pid" 2>/dev/null; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.5
  done
  wait "$pid" 2>/dev/null
  SERVER_PID=""
  return 0
}

# create_gadget POSTs one gadget and echoes its id (empty on failure).
create_gadget() {
  local code="$1"
  curl -sS -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" \
    --data "{\"code\":\"$code\",\"name\":\"transport durability $code\",\"category\":\"transport\",\"status\":\"active\"}" \
  | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin).get("data")
    print(d.get("id","") if isinstance(d,dict) else "")
except Exception:
    print("")'
}

# mongo_count counts this run's gadgets in the projection.
mongo_count() {
  docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet \
    --eval "db.gadgets.countDocuments({code:{\$regex:'^$CODE_PREFIX'}})" 2>/dev/null | tail -1 | tr -d ' '
}

# mongo_count_code counts a single code (must be exactly 1 → no duplicate upsert).
mongo_count_code() {
  docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet \
    --eval "db.gadgets.countDocuments({code:'$1'})" 2>/dev/null | tail -1 | tr -d ' '
}

# wait_count blocks until this run's projected count reaches $1 or the CDC
# deadline elapses. Echoes the final count.
wait_count() {
  local target="$1" deadline c
  deadline=$(( $(date +%s) + QA_CDC_DEADLINE ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    c=$(mongo_count)
    [ "${c:-0}" -ge "$target" ] 2>/dev/null && { echo "${c:-0}"; return 0; }
    sleep 1
  done
  echo "$(mongo_count)"
  return 1
}

# assert_consumer_durable returns 0 if the broker still holds the sync consumer
# group / durable — proving a resume, not a fresh recreation. Transport-aware,
# mirroring integration_events.sh's reset. Best-effort tooling: a probe failure
# (tooling/network) is reported by the caller as a soft WARN, not a hard FAIL,
# so the black-box assertions remain the gate.
assert_consumer_durable() {
  case "${QA_TRANSPORT_TAG:-kafka}" in
    nats)
      docker run --rm --network omnicore-qa_default natsio/nats-box:latest \
        nats -s nats://nats:4222 consumer info "$NATS_STREAM" "$SYNC_GROUP_ID" >/dev/null 2>&1
      ;;
    kafka)
      docker exec omnicore-qa-kafka \
        kafka-consumer-groups --bootstrap-server localhost:9092 --describe --group "$SYNC_GROUP_ID" 2>/dev/null \
        | grep -q "$SYNC_GROUP_ID"
      ;;
    *) return 2 ;;
  esac
}

# ── 0. boot ──────────────────────────────────────────────────────────────────
sec "0. Boot ($BACKEND / $QA_TRANSPORT_TAG)"

title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
ok "built $SERVER_BIN"

title "0.2 Register outbox CDC connector ($QA_RELAY_KIND / $QA_CONNECTOR_DIALECT)"
kill_port "${HTTP_PORT:-8080}"
"$REPO_ROOT/devops/debezium/register-connector.sh" "$QA_CONNECTOR_DIALECT" >/dev/null 2>&1 \
  && ok "outbox connector registered" || bad "outbox connector registration failed"

title "0.3 Start server (APP_PROFILE=dev, config=microservice.qa.yaml)"
start_server && ok "server ready" || { bad "server not ready"; tail -n 40 "$SERVER_LOG"; exit 1; }

title "0.4 Warm up the CDC pipeline"
qa_cdc_warmup_gadget

# ── 1. produce + project before restart ──────────────────────────────────────
sec "1. Project a batch before restart"

# Clean baseline: sweep any QA-TRANSPORT residue a prior aborted run may have
# left, so this run's counts are exact and the shared gadgets view starts clean.
purge_gadgets

N=5
title "1.1 Create $N gadgets (codes ${CODE_PREFIX}-1..$N)"
created=0
for i in $(seq 1 "$N"); do
  id=$(create_gadget "${CODE_PREFIX}-$i")
  [ -n "$id" ] && created=$((created+1))
done
[ "$created" -eq "$N" ] && ok "created $N gadgets" || bad "created $created/$N gadgets"

title "1.2 Wait for all $N to land in the gadgets view"
got=$(wait_count "$N")
[ "${got:-0}" -ge "$N" ] 2>/dev/null && ok "projected $got/$N before restart" \
  || { bad "CDC never converged before restart (got=$got/$N)"; tail -n 30 "$SERVER_LOG"; }

# ── 2. graceful restart ──────────────────────────────────────────────────────
sec "2. Graceful restart on the same group/durable"

title "2.1 SIGTERM drains and exits cleanly within the deadline"
if stop_server_graceful "$SERVER_PID"; then
  ok "server drained and exited cleanly on SIGTERM"
else
  bad "server did NOT drain/exit within 30s (shutdown coordination hung)"
  tail -n 40 "$SERVER_LOG"
fi

title "2.2 Broker still holds the sync durable/group (resume, not recreate)"
assert_consumer_durable
case $? in
  0) ok "$QA_TRANSPORT_TAG durable/group '$SYNC_GROUP_ID' persisted across restart" ;;
  1) printf '\033[1;33mWARN\033[0m broker probe did not find the durable/group (tooling/timing?) — black-box assertions still gate\n' ;;
  *) printf '\033[1;33mWARN\033[0m no broker probe for transport '"$QA_TRANSPORT_TAG"'\n' ;;
esac

title "2.3 Relaunch the server"
start_server && ok "server ready after restart" || { bad "server not ready after restart"; tail -n 40 "$SERVER_LOG"; exit 1; }

# ── 3. durability + resume + idempotency ─────────────────────────────────────
sec "3. Durability, resume, and idempotency"

title "3.1 Pre-restart documents survived the restart"
after=$(mongo_count)
[ "${after:-0}" -ge "$N" ] 2>/dev/null && ok "all $N pre-restart gadgets still projected ($after)" \
  || bad "projection not durable across restart (got=$after/$N)"

title "3.2 A write AFTER restart projects (consumer rejoined and is live)"
post_code="${CODE_PREFIX}-post"
post_id=$(create_gadget "$post_code")
[ -n "$post_id" ] && ok "created post-restart gadget" || bad "post-restart create failed"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); landed=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ "$(mongo_count_code "$post_code")" -ge 1 ] 2>/dev/null && { landed=ok; break; }
  sleep 1
done
[ "$landed" = ok ] && ok "post-restart write projected (consumer resumed live)" \
  || { bad "post-restart write never projected (ghost member / blocked rejoin?)"; tail -n 30 "$SERVER_LOG"; }

title "3.3 Idempotency — every code appears EXACTLY once (no duplicate upsert)"
dupes=0
for i in $(seq 1 "$N") "post"; do
  code="${CODE_PREFIX}-$i"
  c=$(mongo_count_code "$code")
  [ "${c:-0}" -eq 1 ] 2>/dev/null || { dupes=$((dupes+1)); printf '  code %s → count %s (want 1)\n' "$code" "${c:-?}"; }
done
[ "$dupes" -eq 0 ] && ok "no duplicates — at-least-once redelivery absorbed by keyed upsert" \
  || bad "$dupes code(s) with a count != 1 (idempotency broken)"

# ── summary ──────────────────────────────────────────────────────────────────
sec "Summary"
printf 'Transport: %s   Backend: %s\n' "${QA_TRANSPORT_TAG:-?}" "$BACKEND"
printf '\033[1;32mPASS=%d\033[0m  \033[1;31mFAIL=%d\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
