#!/usr/bin/env bash
# ============================================================================
# Shared LANE selector — sourced by every qa/*.sh script.
#
# The QA bench runs TWO transport lanes, keyed by the BACKEND env var and mapped
# 1:1 onto a relational engine + a message transport + a CDC relay, so a single
# `BACKEND=…` selects the whole leg:
#
#   BACKEND=postgres  →  Lane A: Postgres + Kafka + Mongo, relay Debezium CONNECT
#   BACKEND=mysql     →  Lane B: MySQL   + NATS  + Mongo, relay Debezium SERVER
#
# Defaults to postgres so a bare invocation runs lane A. It does TWO things:
#
#   1. Exports the env the framework's YAML interpolation reads, so the SAME
#      microservice.*.yaml runs on either lane — engine (REL_DIALECT / DATABASE_URL
#      / MIGRATIONS_DIR), read side (MONGO_URI / MONGO_DB), transport
#      (TRANSPORT_ENDPOINTS / SYNC_GROUP_ID) — plus the listener ports (HTTP_ADDR /
#      GRPC_ADDR) so both lanes' apps run at once without colliding. Each lane
#      builds its OWN single-transport binary (a build links exactly one
#      transport): `postgres kafka` for A, `mysql nats` for B.
#
#   2. Defines lane-aware shell helpers the suites use INSTEAD of hardcoded
#      `docker exec … psql …` / `mongosh users_views`:
#         qa_db_query "<sql>"   -> run a query, print rows (tab-separated, no header)
#         qa_db_exec  "<sql>"   -> run a statement, discard output
#         qa_db_reset_domain    -> wipe persons+users+addresses+user_configurations+outbox (FK-safe per dialect)
#         qa_uuid_select <expr> -> SELECT expression rendering a UUID column as text
#         qa_uuid_lit  <uuid>   -> a literal matching a UUID column in a WHERE
#      plus the variables QA_MONGO_DB / QA_BUILD_TAGS / QA_TRANSPORT_TAG /
#      QA_RELAY_KIND / QA_CONNECTOR_DIALECT / QA_DB_CONTAINER / QA_MONGO_CONTAINER /
#      HTTP_PORT / GRPC_PORT / BASE / GRPC_BASE.
#
# This is the lane-driven harness: one set of scripts, one set of expected
# results, switched by BACKEND — never two harnesses, never an edited assertion.
# ============================================================================

BACKEND="${BACKEND:-postgres}"

# Shared read side lives in one Mongo container; the lanes isolate on DB name.
QA_MONGO_CONTAINER="omnicore-qa-mongo"

case "$BACKEND" in
  postgres)
    export REL_DIALECT="postgres"
    export DATABASE_URL="${DATABASE_URL:-postgres://omnicore:omnicore@localhost:5433/users_db?sslmode=disable}"
    export MIGRATIONS_DIR="./migrations/postgres"
    export MONGO_URI="${MONGO_URI:-mongodb://localhost:27028}"
    export MONGO_DB="users_views"
    export SYNC_GROUP_ID="omnicore-example-users-sync"
    export INTEGRATION_GROUP_ID="omnicore-example-users-integration"
    # Lane A transport = Kafka (external listener on the host).
    export TRANSPORT_ENDPOINTS="${TRANSPORT_ENDPOINTS:-localhost:9094}"
    # Lane A listener ports (distinct from lane B → both run in parallel).
    export HTTP_ADDR=":8081"
    export GRPC_ADDR=":9091"
    export BASE="http://localhost:8081"
    export GRPC_BASE="http://localhost:9091"
    export ECHO_URL="http://localhost:8081"       # httpclient echo self-calls
    HTTP_PORT="8081"; export GRPC_PORT="9091"      # GRPC_PORT read by the yaml self-call baseURL
    # Per-lane label in the shared Jaeger so the two lanes' traces never mix.
    export OTEL_SERVICE_NAME="omnicore-example-users-postgres"
    # Per-lane Redis so cache.sh can stop/start its own broker without disturbing
    # the other lane (a shared container would collide under parallel lanes).
    export REDIS_ADDR="localhost:6380"; export SHARED_REDIS_ADDR="localhost:6380"
    export REDIS_KEY_PREFIX="omnicore-example-users-cache-pg"
    export SHARED_REDIS_KEY_PREFIX="omnicore-example-users-shared-pg"
    QA_REDIS_SERVICE="redis"

    QA_BUILD_TAGS="postgres kafka"
    QA_TRANSPORT_TAG="kafka"
    QA_RELAY_KIND="connect"
    QA_DB_CONTAINER="omnicore-qa-postgres"
    QA_MONGO_DB="users_views"
    QA_CONNECTOR_DIALECT="postgres"

    qa_db_query() { docker exec "$QA_DB_CONTAINER" psql -U omnicore -d users_db -tA -c "$1"; }
    qa_db_exec()  { docker exec "$QA_DB_CONTAINER" psql -U omnicore -d users_db -c "$1" >/dev/null; }
    qa_db_reset_domain() {
      # persons is the SharedBase root; CASCADE drops every dependent role/child/
      # sibling row (users + employees graphs) in FK order.
      docker exec "$QA_DB_CONTAINER" psql -U omnicore -d users_db -c \
        "TRUNCATE TABLE persons, users, addresses, user_configurations, employees, employee_bank_accounts, employee_dependents, dependent_health_plans, employee_job_histories CASCADE; TRUNCATE TABLE outbox;" >/dev/null
    }
    # PG renders uuid columns as text already; the expression is used verbatim.
    qa_uuid_select() { printf '%s' "$1"; }
    # PG compares a uuid column to a quoted literal directly.
    qa_uuid_lit() { printf "'%s'" "$1"; }
    ;;

  mysql)
    export REL_DIALECT="mysql"
    export DATABASE_URL="${DATABASE_URL_MYSQL:-omnicore:omnicore@tcp(localhost:3317)/users_db}"
    export MIGRATIONS_DIR="./migrations/mysql"
    export MONGO_URI="${MONGO_URI:-mongodb://localhost:27028}"
    export MONGO_DB="users_views_mysql"
    export SYNC_GROUP_ID="omnicore-example-users-sync-mysql"
    export INTEGRATION_GROUP_ID="omnicore-example-users-integration-mysql"
    # Lane B transport = NATS JetStream (shifted host port).
    export TRANSPORT_ENDPOINTS="${TRANSPORT_ENDPOINTS:-localhost:4232}"
    # Lane B listener ports.
    export HTTP_ADDR=":8082"
    export GRPC_ADDR=":9092"
    export BASE="http://localhost:8082"
    export GRPC_BASE="http://localhost:9092"
    export ECHO_URL="http://localhost:8082"       # httpclient echo self-calls
    HTTP_PORT="8082"; export GRPC_PORT="9092"      # GRPC_PORT read by the yaml self-call baseURL
    # Per-lane label in the shared Jaeger so the two lanes' traces never mix.
    export OTEL_SERVICE_NAME="omnicore-example-users-mysql"
    # Per-lane Redis so cache.sh can stop/start its own broker without disturbing
    # the other lane (a shared container would collide under parallel lanes).
    export REDIS_ADDR="localhost:6381"; export SHARED_REDIS_ADDR="localhost:6381"
    export REDIS_KEY_PREFIX="omnicore-example-users-cache-mysql"
    export SHARED_REDIS_KEY_PREFIX="omnicore-example-users-shared-mysql"
    QA_REDIS_SERVICE="redis-mysql"

    QA_BUILD_TAGS="mysql nats"
    QA_TRANSPORT_TAG="nats"
    QA_RELAY_KIND="server"
    QA_DB_CONTAINER="omnicore-qa-mysql"
    QA_MONGO_DB="users_views_mysql"
    QA_CONNECTOR_DIALECT="mysql"

    qa_db_query() { docker exec "$QA_DB_CONTAINER" mysql -uomnicore -pomnicore -D users_db -N -B -e "$1" 2>/dev/null; }
    qa_db_exec()  { docker exec "$QA_DB_CONTAINER" mysql -uomnicore -pomnicore -D users_db -e "$1" 2>/dev/null; }
    qa_db_reset_domain() {
      # MySQL cannot TRUNCATE a table referenced by a FK; disable the check and
      # truncate child-first (user_configurations + addresses + users → persons).
      docker exec "$QA_DB_CONTAINER" mysql -uomnicore -pomnicore -D users_db 2>/dev/null -e \
        "SET FOREIGN_KEY_CHECKS=0; TRUNCATE TABLE user_configurations; TRUNCATE TABLE addresses; TRUNCATE TABLE users; TRUNCATE TABLE dependent_health_plans; TRUNCATE TABLE employee_dependents; TRUNCATE TABLE employee_job_histories; TRUNCATE TABLE employee_bank_accounts; TRUNCATE TABLE employees; TRUNCATE TABLE persons; TRUNCATE TABLE outbox; SET FOREIGN_KEY_CHECKS=1;"
    }
    # id/user_id are BINARY(16); BIN_TO_UUID(col, 0) restores the canonical text
    # (0 = no time-low swap, matching the framework's standard-order u[:] bytes).
    qa_uuid_select() { printf 'BIN_TO_UUID(%s, 0)' "$1"; }
    # Compare a BINARY(16) column to a UUID string via UUID_TO_BIN(text, 0).
    qa_uuid_lit() { printf "UUID_TO_BIN('%s', 0)" "$1"; }
    ;;

  *)
    echo "qa/_backend.sh: unknown BACKEND='$BACKEND' (want postgres|mysql)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

# Mongo collection wipe used by several suites (lane-independent, but the DB
# name differs per lane).
qa_mongo_reset() {
  docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval "db.users.deleteMany({}); db.employees.deleteMany({}); db.persons.deleteMany({});" >/dev/null 2>&1
}

# ── CDC pipeline knobs + warmup ──────────────────────────────────────────────

# QA_CDC_DEADLINE bounds every "wait for the pipeline to land data" loop in the
# CDC-dependent suites. The waits exit as soon as the condition holds, so a
# generous ceiling costs nothing on a healthy bench — it only buys headroom for
# the real-world slow cases: durable-consumer/connector setup after the
# back-to-back server boots the self-managed suites perform, relay restarts on a
# backend switch, cold page caches. Override per run:
# QA_CDC_DEADLINE=180 ./qa/run.sh
QA_CDC_DEADLINE="${QA_CDC_DEADLINE:-90}"

# qa_cdc_warmup_gadget proves the WHOLE pipeline (outbox → CDC relay → broker →
# SyncEngine consumer → Mongo upsert) is hot before a suite starts asserting
# under per-step deadlines: it creates a sentinel gadget, waits for it to land in
# the gadgets view, then hard-deletes it. Call it right after the server is
# healthy and BEFORE the suite's clean-baseline step (the reset sweeps any
# leftovers). Non-fatal by design — a cold pipeline surfaces as a WARN here and
# the suite's own deadlines still apply.
qa_cdc_warmup_gadget() {
  local base="${BASE:-http://localhost:8080}" code id deadline c
  code="QA-WARMUP-$$-$(date +%s)"
  id=$(curl -sS -X POST "$base/qa/gadgets" -H "Content-Type: application/json" \
    --data "{\"code\":\"$code\",\"name\":\"CDC warmup sentinel\",\"category\":\"warmup\",\"status\":\"active\"}" \
    | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data")
print(d.get("id","") if isinstance(d,dict) else "")' 2>/dev/null)
  deadline=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    c=$(docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet \
      --eval "db.gadgets.countDocuments({code:'$code'})" 2>/dev/null | tail -1 | tr -d ' ')
    [ "${c:-0}" -ge 1 ] 2>/dev/null && break
    sleep 1
  done
  if [ "${c:-0}" -ge 1 ] 2>/dev/null; then
    echo "cdc warmup: pipeline hot ($(( $(date +%s) - (deadline - 120) ))s)"
  else
    echo "WARN cdc warmup: sentinel never landed in Mongo after 120s — CDC waits may flake" >&2
  fi
  [ -n "$id" ] && curl -sS -o /dev/null -X DELETE "$base/qa/gadgets/$id" 2>/dev/null || true
}
