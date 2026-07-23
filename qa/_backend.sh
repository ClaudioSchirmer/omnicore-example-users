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
#   BACKEND=sqlserver →  Lane C: SQL Server + Kafka + Mongo, relay Debezium CONNECT
#                        (local container by default; QA_SQLSERVER_CONTEXT +
#                         QA_SQLSERVER_DB_HOST point the lane at a remote engine)
#   BACKEND=oracle    →  Lane D: Oracle Free 23ai + NATS + Mongo, relay Debezium SERVER
#                        (local container by default; QA_ORACLE_CONTEXT +
#                         QA_ORACLE_DB_HOST point the lane at a remote engine)
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
    # Row-cap fragments for hand-written suite SQL: PG caps with a LIMIT tail.
    export QA_SQL_TOP1=""; export QA_SQL_LIMIT1="LIMIT 1"
    export QA_SQL_FALSE="false"; export QA_SQL_TRUE="true"
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
    # Row-cap fragments for hand-written suite SQL: MySQL caps with a LIMIT tail.
    export QA_SQL_TOP1=""; export QA_SQL_LIMIT1="LIMIT 1"
    export QA_SQL_FALSE="false"; export QA_SQL_TRUE="true"
    ;;

  sqlserver)
    # Lane C: SQL Server + Kafka (lane A's broker + Connect) + Mongo. The
    # container is LOCAL by default; a remote docker engine (e.g. a Windows
    # bench) is opt-in via env — the only two knobs that move the lane:
    #   QA_SQLSERVER_CONTEXT  docker context name (default: the local engine)
    #   QA_SQLSERVER_DB_HOST  where host port 14333 answers (default 127.0.0.1)
    export QA_DOCKER_CONTEXT="${QA_SQLSERVER_CONTEXT:-default}"
    QA_SQLSERVER_DB_HOST="${QA_SQLSERVER_DB_HOST:-127.0.0.1}"
    QA_SQLSERVER_SA_PASSWORD="${QA_SQLSERVER_SA_PASSWORD:-OmnicoreQA!2026}"

    export REL_DIALECT="sqlserver"
    export DATABASE_URL="${DATABASE_URL_SQLSERVER:-server=${QA_SQLSERVER_DB_HOST};port=14333;user id=sa;password=${QA_SQLSERVER_SA_PASSWORD};database=users_db;encrypt=true;TrustServerCertificate=true}"
    export MIGRATIONS_DIR="./migrations/sqlserver"
    export MONGO_URI="${MONGO_URI:-mongodb://localhost:27028}"
    export MONGO_DB="users_views_sqlserver"
    export SYNC_GROUP_ID="omnicore-example-users-sync-sqlserver"
    export INTEGRATION_GROUP_ID="omnicore-example-users-integration-sqlserver"
    # Lane C transport = its OWN Kafka broker (external :9095) + Connect
    # (:8085): SyncEngine topic names are the cross-service contract
    # (<table>.events, no suffix knob by design), so sharing lane A's broker
    # would cross the lanes' events. Isolation mirrors lane B owning its NATS.
    export TRANSPORT_ENDPOINTS="${TRANSPORT_ENDPOINTS:-localhost:9095}"
    # Lane C listener ports.
    export HTTP_ADDR=":8084"
    export GRPC_ADDR=":9093"
    export BASE="http://localhost:8084"
    export GRPC_BASE="http://localhost:9093"
    export ECHO_URL="http://localhost:8084"       # httpclient echo self-calls
    HTTP_PORT="8084"; export GRPC_PORT="9093"      # GRPC_PORT read by the yaml self-call baseURL
    export OTEL_SERVICE_NAME="omnicore-example-users-sqlserver"
    export REDIS_ADDR="localhost:6382"; export SHARED_REDIS_ADDR="localhost:6382"
    export REDIS_KEY_PREFIX="omnicore-example-users-cache-mssql"
    export SHARED_REDIS_KEY_PREFIX="omnicore-example-users-shared-mssql"
    QA_REDIS_SERVICE="redis-sqlserver"

    QA_BUILD_TAGS="sqlserver kafka"
    QA_TRANSPORT_TAG="kafka"
    QA_RELAY_KIND="connect"
    # Lane-scoped broker probe (transport.sh): lane C owns its Kafka.
    export QA_KAFKA_CONTAINER="omnicore-qa-kafka-sqlserver"
    QA_DB_CONTAINER="omnicore-qa-sqlserver"
    QA_MONGO_DB="users_views_sqlserver"
    QA_CONNECTOR_DIALECT="sqlserver"

    _qa_sqlcmd() { # runs sqlcmd inside the lane's container, honoring the context
      docker --context "$QA_DOCKER_CONTEXT" exec "$QA_DB_CONTAINER" /opt/mssql-tools18/bin/sqlcmd \
        -C -S localhost -U sa -P "$QA_SQLSERVER_SA_PASSWORD" "$@"
    }
    qa_db_query() { _qa_sqlcmd -d users_db -h -1 -W -s "$(printf '\t')" -Q "SET NOCOUNT ON; $1" | tr -d '\r'; }
    qa_db_exec()  { _qa_sqlcmd -d users_db -Q "$1" >/dev/null; }
    qa_db_reset_domain() {
      # No TRUNCATE ... CASCADE on SQL Server and TRUNCATE refuses FK-referenced
      # tables — DELETE child-first (identical row-visibility outcome; these
      # are small QA tables).
      qa_db_exec "DELETE FROM dependent_health_plans; DELETE FROM employee_job_histories; DELETE FROM employee_dependents; DELETE FROM employee_bank_accounts; DELETE FROM employees; DELETE FROM user_configurations; DELETE FROM addresses; DELETE FROM users; DELETE FROM persons; DELETE FROM outbox;"
    }
    # id columns are BINARY(16); render as the lowercase canonical uuid text
    # (CONVERT style 2 = bare hex; STUFF inserts the dashes).
    qa_uuid_select() { printf "LOWER(STUFF(STUFF(STUFF(STUFF(CONVERT(CHAR(32), %s, 2),9,0,'-'),14,0,'-'),19,0,'-'),24,0,'-'))" "$1"; }
    # Compare a BINARY(16) column to a UUID string (strip dashes, hex→binary).
    qa_uuid_lit() { printf "CONVERT(BINARY(16), REPLACE('%s','-',''), 2)" "$1"; }
    # Row-cap fragments for hand-written suite SQL: T-SQL caps with a
    # SELECT-head TOP, not a LIMIT tail.
    export QA_SQL_TOP1="TOP 1"; export QA_SQL_LIMIT1=""
    # T-SQL BIT has no true/false literals — 1/0.
    export QA_SQL_FALSE="0"; export QA_SQL_TRUE="1"

    # SQL Server images create no database on boot (no MYSQL_DATABASE /
    # POSTGRES_DB equivalent) — ensure users_db exists, idempotently. Harmless
    # no-op when the container is not up yet (the caller boots it first).
    _qa_sqlcmd -Q "IF DB_ID('users_db') IS NULL CREATE DATABASE users_db" >/dev/null 2>&1 || true
    ;;

  oracle)
    # Lane D: Oracle Free 23ai + NATS JetStream (its OWN server) + Mongo, relay
    # Debezium SERVER — the matrix balance the maintainer chose (2 lanes per
    # transport: A/C on Kafka, B/D on NATS). The DB container is LOCAL by
    # default; a remote docker engine is opt-in via env — the only two knobs
    # that move the lane:
    #   QA_ORACLE_CONTEXT  docker context name (default: the local engine)
    #   QA_ORACLE_DB_HOST  where host port 15211 answers (default 127.0.0.1)
    # There is no CREATE DATABASE step: on Oracle the schema IS the app user
    # (`omnicore`, created by the gvenzl image in FREEPDB1 on first boot; the
    # bench init script grants it EXECUTE ON DBMS_LOCK + SELECT_CATALOG_ROLE).
    export QA_DOCKER_CONTEXT="${QA_ORACLE_CONTEXT:-default}"
    QA_ORACLE_DB_HOST="${QA_ORACLE_DB_HOST:-127.0.0.1}"
    QA_ORACLE_APP_PASSWORD="${QA_ORACLE_APP_PASSWORD:-omnicore}"

    export REL_DIALECT="oracle"
    export DATABASE_URL="${DATABASE_URL_ORACLE:-oracle://omnicore:${QA_ORACLE_APP_PASSWORD}@${QA_ORACLE_DB_HOST}:15211/FREEPDB1}"
    export MIGRATIONS_DIR="./migrations/oracle"
    export MONGO_URI="${MONGO_URI:-mongodb://localhost:27028}"
    export MONGO_DB="users_views_oracle"
    export SYNC_GROUP_ID="omnicore-example-users-sync-oracle"
    export INTEGRATION_GROUP_ID="omnicore-example-users-integration-oracle"
    # Lane D transport = its OWN NATS JetStream (host :4242), for the lane-C
    # reason: subject names are the cross-service contract
    # (omnicore.<table>.events, no suffix knob by design), so sharing lane B's
    # JetStream would cross the lanes' events.
    export TRANSPORT_ENDPOINTS="${TRANSPORT_ENDPOINTS:-localhost:4242}"
    # Lane D listener ports.
    export HTTP_ADDR=":8086"
    export GRPC_ADDR=":9097"
    export BASE="http://localhost:8086"
    export GRPC_BASE="http://localhost:9097"
    export ECHO_URL="http://localhost:8086"       # httpclient echo self-calls
    HTTP_PORT="8086"; export GRPC_PORT="9097"      # GRPC_PORT read by the yaml self-call baseURL
    export OTEL_SERVICE_NAME="omnicore-example-users-oracle"
    export REDIS_ADDR="localhost:6383"; export SHARED_REDIS_ADDR="localhost:6383"
    export REDIS_KEY_PREFIX="omnicore-example-users-cache-oracle"
    export SHARED_REDIS_KEY_PREFIX="omnicore-example-users-shared-oracle"
    QA_REDIS_SERVICE="redis-oracle"

    QA_BUILD_TAGS="oracle nats"
    QA_TRANSPORT_TAG="nats"
    QA_RELAY_KIND="server"
    # Lane-scoped broker probes (transport.sh): lane D owns its NATS.
    export QA_NATS_URL="nats://nats-oracle:4222"
    QA_DB_CONTAINER="omnicore-qa-oracle"
    QA_MONGO_DB="users_views_oracle"
    QA_CONNECTOR_DIALECT="oracle"

    _qa_sqlplus() { # runs a SQL script (stdin) inside the lane's container, honoring the context
      docker --context "$QA_DOCKER_CONTEXT" exec -i "$QA_DB_CONTAINER" sqlplus -S \
        "omnicore/${QA_ORACLE_APP_PASSWORD}@localhost/FREEPDB1"
    }
    # _qa_sql_terminated normalizes a suite statement for sqlplus: the other
    # CLIs (psql -c / mysql -e / sqlcmd -Q) execute a bare statement — and run
    # several statements handed on one line — but sqlplus only runs what a ';'
    # AT END OF LINE terminates. So: trailing whitespace/semicolons stripped,
    # one terminator re-appended, and every internal ';' gains a newline so a
    # multi-statement string (qa_db_reset_domain's child-first DELETEs)
    # executes statement by statement. (No suite SQL carries a ';' inside a
    # literal; keep it that way.)
    _qa_sql_terminated() {
      local s="$1" nl=$'\n'
      while [ -n "$s" ] && { [ "${s: -1}" = ";" ] || [[ "${s: -1}" =~ [[:space:]] ]]; }; do s="${s%?}"; done
      s="${s//;/;$nl}"
      printf '%s;\n' "$s"
    }
    # Clean scripting output: no headers/feedback/pagination, tab column
    # separator, whitespace trimmed per line (sqlplus pads numeric columns).
    qa_db_query() {
      { printf 'SET PAGESIZE 0 FEEDBACK OFF HEADING OFF VERIFY OFF TRIMSPOOL ON TRIMOUT ON LINESIZE 32767 COLSEP "\t"\n'; _qa_sql_terminated "$1"; } \
        | _qa_sqlplus | tr -d '\r' \
        | sed -e 's/[[:space:]]*'$'\t''[[:space:]]*/'$'\t''/g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'
    }
    qa_db_exec()  { _qa_sql_terminated "$1" | _qa_sqlplus >/dev/null; }
    qa_db_reset_domain() {
      # No TRUNCATE CASCADE on Oracle and TRUNCATE refuses FK-referenced
      # tables — DELETE child-first (identical row-visibility outcome; these
      # are small QA tables).
      qa_db_exec "DELETE FROM dependent_health_plans; DELETE FROM employee_job_histories; DELETE FROM employee_dependents; DELETE FROM employee_bank_accounts; DELETE FROM employees; DELETE FROM user_configurations; DELETE FROM addresses; DELETE FROM users; DELETE FROM persons; DELETE FROM outbox;"
    }
    # id columns are RAW(16); render as the lowercase canonical uuid text.
    qa_uuid_select() { printf "LOWER(REGEXP_REPLACE(RAWTOHEX(%s), '(.{8})(.{4})(.{4})(.{4})(.{12})', '\\\\1-\\\\2-\\\\3-\\\\4-\\\\5'))" "$1"; }
    # Compare a RAW(16) column to a UUID string (strip dashes, hex→raw).
    qa_uuid_lit() { printf "HEXTORAW(REPLACE('%s','-',''))" "$1"; }
    # Row-cap fragments for hand-written suite SQL: Oracle caps with a tail
    # FETCH FIRST clause (valid without ORDER BY), no SELECT-head TOP.
    export QA_SQL_TOP1=""; export QA_SQL_LIMIT1="FETCH FIRST 1 ROWS ONLY"
    # Native 23ai BOOLEAN speaks the standard literals.
    export QA_SQL_FALSE="FALSE"; export QA_SQL_TRUE="TRUE"
    ;;

  *)
    echo "qa/_backend.sh: unknown BACKEND='$BACKEND' (want postgres|mysql|sqlserver|oracle)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

# Mongo collection wipe used by several suites (lane-independent, but the DB
# name differs per lane).
qa_mongo_reset() {
  # Clear the canonical views across ALL physical blue-green slots, not just the
  # bare collection: once schema_evolution/rebuild_scale have flipped a view, its
  # live data sits in a slot (users__0/__1) and the bare collection is empty, so a
  # bare-only deleteMany leaves stale rows in the active slot (they then leak into
  # the next suite reading that view). deleteMany (not drop) preserves indexes;
  # a missing slot collection is a harmless no-op.
  local ev="" v n
  for v in users employees persons; do
    for n in "$v" "${v}__0" "${v}__1"; do
      ev="${ev}db.getCollection('$n').deleteMany({});"
    done
  done
  docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval "$ev" >/dev/null 2>&1
}

# ── Blue-green view-collection resolution ────────────────────────────────────
# Online blue-green rebuilds move a view between its bare <view> and the two
# physical slots <view>__0 / <view>__1 (registry.active_collection names the live
# one; NULL = bare). The framework's ViewReader resolves this transparently, so
# suites reading through the HTTP API never notice. Suites that peek at Mongo
# DIRECTLY (mongosh countDocuments/findOne for CDC-convergence or value checks)
# must resolve the SAME pointer, or they read an empty bare collection once a view
# has been rebuilt into a slot and never come back.

# qa_view_coll <view> — echo the physical Mongo collection <view> currently lives
# in (its active slot, or the bare name when the registry has no row / a NULL
# pointer). Lane-aware via qa_db_query.
qa_view_coll() {
  local c
  c=$(qa_db_query "SELECT COALESCE(active_collection,'$1') FROM omnicore_mongo_views WHERE view_name='$1'" 2>/dev/null | tr -d '[:space:]')
  printf '%s' "${c:-$1}"
}

# qa_view_drop <view...> — drop EVERY physical collection each view can occupy (the
# bare <view> AND both slots <view>__0 / <view>__1) in the lane's view DB. Removes
# a view's data regardless of which slot is live, so no orphan slot survives to
# inflate the next suite's counts. Best-effort (a missing collection is a no-op).
qa_view_drop() {
  local list="" v
  for v in "$@"; do list="${list}'$v','${v}__0','${v}__1',"; done
  [ -z "$list" ] && return 0
  docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval \
    "[${list%,}].forEach(function(n){db.getCollection(n).drop()})" >/dev/null 2>&1 || true
}

# qa_view_clear <view...> — EMPTY each view's active collection (deleteMany), never
# drop it. Use for a mid-run reset while the server is UP: a drop would lose the
# view's declared indexes (e.g. the ?search= text index), which only ApplyMongoSpecs
# re-creates at boot — an in-flight CDC upsert would recreate the collection bare.
qa_view_clear() {
  local ev="" v c
  for v in "$@"; do c=$(qa_view_coll "$v"); ev="${ev}db.getCollection('$c').deleteMany({});"; done
  [ -z "$ev" ] && return 0
  docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval "$ev" >/dev/null 2>&1 || true
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
  local base="${BASE:-http://localhost:8080}" code id deadline c gcoll
  code="QA-WARMUP-$$-$(date +%s)"
  id=$(curl -sS -X POST "$base/qa/gadgets" -H "Content-Type: application/json" \
    --data "{\"code\":\"$code\",\"name\":\"CDC warmup sentinel\",\"category\":\"warmup\",\"status\":\"active\"}" \
    | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data")
print(d.get("id","") if isinstance(d,dict) else "")' 2>/dev/null)
  gcoll=$(qa_view_coll gadgets)   # resolve the active gadgets slot (blue-green)
  deadline=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    c=$(docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet \
      --eval "db.getCollection('$gcoll').countDocuments({code:'$code'})" 2>/dev/null | tail -1 | tr -d ' ')
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


# qa_broker_reset — ground the ENTITY event backlog after an out-of-band SQL
# wipe. Under the v2 payload-direct projection, redelivered/stale events are
# STATE (not routing hints): a leftover broker tail from before the wipe would
# materialize ghost documents for rows that no longer exist (the old
# consult-always model silently absorbed this; event-carried state cannot, by
# design — see the framework's read-lifecycle contract). Mirrors what an
# operator must do alongside out-of-band table surgery.
#   kafka: reset the sync group's offsets to LATEST (the group is empty while
#          the server is down; the PRODUCER side — Debezium and its topics —
#          is never touched, so the CDC pipeline stays healthy);
#   nats:  purge the shared JetStream stream (publisher-safe; durables survive,
#          messages gone).
# Best-effort: tooling failures are warnings — the caller's asserts remain the
# gate.
qa_broker_reset() {
  local group="${1:-omnicore-example-users-sync}"
  case "${QA_TRANSPORT_TAG:-kafka}" in
    kafka)
      docker exec "${QA_KAFKA_CONTAINER:-omnicore-qa-kafka}" \
        kafka-consumer-groups --bootstrap-server localhost:9092 --group "$group" \
        --reset-offsets --to-latest --all-topics --execute >/dev/null 2>&1 || true
      ;;
    nats)
      docker run --rm --network omnicore-qa_default natsio/nats-box:latest \
        nats -s "${QA_NATS_URL:-nats://nats:4222}" stream purge OMNICORE_EVENTS -f >/dev/null 2>&1 || true
      ;;
  esac
}
