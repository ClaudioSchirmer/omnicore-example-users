#!/usr/bin/env bash
# ============================================================================
# Shared backend selector — sourced by every qa/*.sh script.
#
# Selects the relational backend via the BACKEND env var (postgres | mysql),
# defaulting to postgres so existing invocations are byte-identical. It does TWO
# things:
#
#   1. Exports the env vars the framework's YAML interpolation reads, so the SAME
#      microservice.*.yaml runs on either backend (the yamls declare
#      ${REL_DIALECT:postgres} / ${MIGRATIONS_DIR:./migrations/postgres} /
#      ${DATABASE_URL:...} / ${MONGO_DB:users_views} / ${SYNC_GROUP_ID:...}).
#      A single dual-engine binary (-tags 'postgres mysql') links both engines
#      and picks the dialect at boot from relational.dialect.
#
#   2. Defines backend-aware shell helpers the suites use INSTEAD of hardcoded
#      `docker exec omnicore-example-postgres psql ...` / `mongosh users_views`:
#         qa_db_query "<sql>"   -> run a query, print rows (tab-separated, no header)
#         qa_db_exec  "<sql>"   -> run a statement, discard output
#         qa_db_reset_domain    -> wipe persons+users+addresses+user_configurations+outbox (FK-safe per dialect)
#         qa_uuid_select <expr> -> SELECT expression that renders a UUID column as
#                                  its canonical text (id is uuid on PG, BINARY(16)
#                                  on MySQL — BIN_TO_UUID restores the text form)
#         qa_uuid_lit  <uuid>   -> a literal that matches a UUID column in a WHERE
#                                  (plain quoted text on PG, UUID_TO_BIN on MySQL)
#      plus the variables QA_MONGO_DB / QA_BUILD_TAGS / QA_CONNECTOR_DIALECT /
#      QA_DB_CONTAINER.
#
# This is the dialect-driven harness: one set of scripts, one set of expected
# results, switched by BACKEND — never two harnesses, never an edited assertion.
# ============================================================================

BACKEND="${BACKEND:-postgres}"

# One binary serves both backends; the dialect is a runtime YAML choice.
QA_BUILD_TAGS="postgres mysql"

case "$BACKEND" in
  postgres)
    export REL_DIALECT="postgres"
    export DATABASE_URL="${DATABASE_URL:-postgres://omnicore:omnicore@localhost:5433/users_db?sslmode=disable}"
    export MIGRATIONS_DIR="./migrations/postgres"
    export MONGO_DB="users_views"
    export SYNC_GROUP_ID="omnicore-example-users-sync"
    export INTEGRATION_GROUP_ID="omnicore-example-users-integration"
    QA_DB_CONTAINER="omnicore-example-postgres"
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
    export DATABASE_URL="${DATABASE_URL_MYSQL:-omnicore:omnicore@tcp(localhost:3307)/users_db}"
    export MIGRATIONS_DIR="./migrations/mysql"
    export MONGO_DB="users_views_mysql"
    export SYNC_GROUP_ID="omnicore-example-users-sync-mysql"
    export INTEGRATION_GROUP_ID="omnicore-example-users-integration-mysql"
    QA_DB_CONTAINER="omnicore-example-mysql"
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

# Mongo collection wipe used by several suites (dialect-independent, but the DB
# name differs per backend).
qa_mongo_reset() {
  docker exec omnicore-example-mongo mongosh "$QA_MONGO_DB" --quiet --eval "db.users.deleteMany({}); db.employees.deleteMany({}); db.persons.deleteMany({});" >/dev/null 2>&1
}

# ── CDC pipeline knobs + warmup ──────────────────────────────────────────────

# QA_CDC_DEADLINE bounds every "wait for the pipeline to land data" loop in the
# CDC-dependent suites. The waits exit as soon as the condition holds, so a
# generous ceiling costs nothing on a healthy bench — it only buys headroom for
# the real-world slow cases: Kafka consumer-group rebalances after the
# back-to-back server boots the self-managed suites perform (a leaving member
# holds its group slot until the session times out, and the next boot's join
# blocks on that), Debezium task restarts, cold page caches. Override per run:
# QA_CDC_DEADLINE=180 ./qa/run.sh
QA_CDC_DEADLINE="${QA_CDC_DEADLINE:-90}"

# qa_cdc_warmup_gadget proves the WHOLE pipeline (outbox → Debezium → Kafka →
# SyncEngine consumer joined → Mongo upsert) is hot before a suite starts
# asserting under per-step deadlines: it creates a sentinel gadget, waits for
# it to land in the gadgets view, then hard-deletes it. Call it right after
# the server is healthy and BEFORE the suite's clean-baseline step (the reset
# sweeps any leftovers). Non-fatal by design — a cold pipeline surfaces as a
# WARN here and the suite's own deadlines still apply.
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
    c=$(docker exec omnicore-example-mongo mongosh "$QA_MONGO_DB" --quiet \
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
