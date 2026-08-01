#!/usr/bin/env bash
# ============================================================================
# SQLite QA — the ISOLATED, individual run (NOT a normal lane).
#
# WHY IT IS SEPARATE (read before extending): the four run.sh lanes are each an
# engine + broker + Mongo projection pipeline, and every *.sh suite reads the
# result through the MONGO VIEW (outbox → CDC relay → broker → SyncEngine →
# Mongo). SQLite has NO CDC source (Debezium cannot tail a SQLite file), so
# Mongo-projected views never materialize on it — by design, not a bug. SQLite's
# read side is the RELATIONAL view (served straight from the SoR). It therefore
# CANNOT run the projection-dependent suites as a lane, and is run APART:
#
#   ./qa/run.sh sqlite     → runs ONLY this isolated step (no lanes)
#   ./qa/run.sh            → runs the four DB lanes, THEN this step at the end
#
# This step boots the service with the SQLite engine as the System of Record and
# asserts the WRITE side end to end over real HTTP — the aggregate write (User =
# person + role + addresses), the SharedBase reuse across roles (Employee over
# the same Person), soft-delete cascade + convergence, and hard delete — each
# VERIFIED by querying the app.db file directly with sqlite3 (the read side that
# does not depend on a projection). Boot + migrations + probes are proven too.
# Mongo + transport from the QA bench are attached only so the service boots (its
# views are declared Mongo-backed); those views stay empty, as expected.
#
# Self-contained: it does NOT source _backend.sh (whose helpers are Docker/lane
# specific). It needs only the Go toolchain, sqlite3, and the QA-bench Mongo/NATS
# for boot. Run from anywhere:  bash qa/sqlite.sh
# ============================================================================
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- isolated SQLite environment (own port, own db file, own Mongo db) --------
export REL_DIALECT="sqlite"
DB_FILE="${SQLITE_QA_DB:-/tmp/omnicore-example-users-qa-sqlite.db}"
export DATABASE_URL="file:${DB_FILE}"
export MIGRATIONS_DIR="./migrations/sqlite"
export MONGO_URI="${MONGO_URI:-mongodb://localhost:27028/?directConnection=true}"
export MONGO_DB="${MONGO_DB:-users_views_sqlite}"
export TRANSPORT_ENDPOINTS="${TRANSPORT_ENDPOINTS:-localhost:4232}"
export SYNC_GROUP_ID="omnicore-example-users-sync-sqlite"
export INTEGRATION_GROUP_ID="omnicore-example-users-integration-sqlite"
export HTTP_ADDR=":8087"; HTTP_PORT="8087"
export GRPC_ADDR=":9098"; export GRPC_PORT="9098"
BASE="http://localhost:8087"
SERVER_BIN="/tmp/omnicore-example-users-qa-sqlite"
SERVER_LOG="/tmp/omnicore-example-users-qa-sqlite.log"

PASS=0; FAIL=0; SERVER_PID=""
sec()   { printf '\n\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port "$HTTP_PORT"
  rm -f "$DB_FILE" "$DB_FILE"-wal "$DB_FILE"-shm
}
trap cleanup EXIT INT TERM

# db <sql> — query the app.db directly (the SoR read side, no projection).
db() { sqlite3 "$DB_FILE" "$1"; }
# post <path> <json> — POST and echo the HTTP status into $STATUS.
post() { STATUS=$(curl -sS -m 10 -o /tmp/qa-sqlite.body -w "%{http_code}" -X POST "$BASE$1" -H "Content-Type: application/json" --data "$2"); }
patch() { STATUS=$(curl -sS -m 10 -o /tmp/qa-sqlite.body -w "%{http_code}" -X PATCH "$BASE$1"); }
delete() { STATUS=$(curl -sS -m 10 -o /tmp/qa-sqlite.body -w "%{http_code}" -X DELETE "$BASE$1"); }
jsonq() { python3 -c "import sys,json; d=json.load(open('/tmp/qa-sqlite.body')); print($1)" 2>/dev/null; }

##############################################################################
sec "0. Build (CGO_ENABLED=0, -tags 'sqlite nats') + boot infra as SoR"
##############################################################################
title "0.1 Static build with the pure-Go sqlite engine"
rm -f "$DB_FILE" "$DB_FILE"-wal "$DB_FILE"-shm
if CGO_ENABLED=0 go build -tags 'sqlite nats' -o "$SERVER_BIN" ./bootstrap; then
  ok "CGO_ENABLED=0 static build with -tags 'sqlite nats'"
else
  bad "build failed"; exit 1
fi
kill_port "$HTTP_PORT"

title "0.2 Reset the Mongo view DB (drop stale collections from a prior run)"
# The SQLite .db is recreated each run (empty omnicore_mongo_views registry), so a
# collection left populated in users_views_sqlite by a PRIOR run would trip the
# framework's drift guard ("populated collection + no registry row" → boot abort).
# Drop the view DB so mongo.apply starts clean — the same discipline the lane
# suites use via qa_mongo_reset. (SQLite has no CDC, so these views stay empty.)
docker exec omnicore-qa-mongo mongosh --quiet --eval \
  "db.getSiblingDB('${MONGO_DB}').dropDatabase()" >/dev/null 2>&1 \
  && ok "Mongo view DB ${MONGO_DB} reset" || ok "Mongo reset skipped (db already clean / mongosh unavailable)"

title "0.3 Boot (SQLite SoR + QA-bench Mongo/NATS for boot) + migrations autoRun"
APP_PROFILE=dev "$SERVER_BIN" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
ready=""
for _ in $(seq 1 40); do
  if curl -sS -m 2 "$BASE/readyz" 2>/dev/null | grep -q '"status":"ready"'; then ready=ok; break; fi
  kill -0 "$SERVER_PID" 2>/dev/null || { bad "server exited during boot — see $SERVER_LOG"; tail -20 "$SERVER_LOG"; exit 1; }
  sleep 0.5
done
[ "$ready" = ok ] && ok "service ready on SQLite (readyz 200)" || { bad "service never became ready"; tail -20 "$SERVER_LOG"; exit 1; }

title "0.4 The .db file was created next to the run + control plane applied"
[ -f "$DB_FILE" ] && ok "app.db created ($DB_FILE)" || bad "app.db missing"
[ "$(db "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='outbox';")" = "1" ] \
  && ok "framework control plane migrated (outbox table present)" || bad "control plane not applied"
[ "$(db "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='persons';")" = "1" ] \
  && ok "service schema migrated (persons table present)" || bad "service migrations not applied"

##############################################################################
sec "1. Aggregate write (User = person + role + addresses) over real HTTP"
##############################################################################
DOC="90000000001"
title "1.1 POST /users → 201"
post /users "{\"name\":\"Sqlite One\",\"email\":\"sqlite1@example.com\",\"document\":\"$DOC\",\"userName\":\"sqlite1\",\"addresses\":[{\"street\":\"Rua A\",\"number\":\"1\",\"neighborhood\":\"Centro\",\"city\":\"POA\",\"state\":\"RS\",\"zipCode\":\"90000000\",\"country\":\"BR\"}]}"
[ "$STATUS" = "201" ] && ok "POST /users 201" || { bad "POST /users → $STATUS"; cat /tmp/qa-sqlite.body; }
UID1=$(jsonq "d['data']['id']")

title "1.2 the aggregate landed in the .db (person + user + address rows)"
[ "$(db "SELECT count(*) FROM persons WHERE document='$DOC';")" = "1" ] && ok "persons row written" || bad "persons row missing"
[ "$(db "SELECT count(*) FROM users WHERE id='$UID1';")" = "1" ] && ok "users role row written (shared PK)" || bad "users row missing"
[ "$(db "SELECT count(*) FROM addresses WHERE person_id='$UID1';")" = "1" ] && ok "address child row written" || bad "address row missing"
[ "$(db "SELECT user_name FROM users WHERE id='$UID1';")" = "sqlite1" ] && ok "TEXT column round-trips exactly" || bad "user_name mismatch"

##############################################################################
sec "2. SharedBase reuse — Employee role over the SAME Person"
##############################################################################
title "2.1 POST /employees with the same document → 201, reuses the person"
post /employees "{\"name\":\"Sqlite One\",\"email\":\"sqlite1@example.com\",\"document\":\"$DOC\",\"employeeNumber\":\"EMP-1\"}"
[ "$STATUS" = "201" ] && ok "POST /employees 201" || { bad "POST /employees → $STATUS"; cat /tmp/qa-sqlite.body; }
EID1=$(jsonq "d['data']['id']")
[ "$UID1" = "$EID1" ] && ok "shared PK across roles (users.id == employees.id == UUIDv5(document))" || bad "role ids diverge: $UID1 vs $EID1"
[ "$(db "SELECT count(*) FROM persons WHERE document='$DOC';")" = "1" ] && ok "exactly ONE persons row backs both roles" || bad "person duplicated"

##############################################################################
sec "3. Soft-delete cascade + hard delete (savepoint purge veto path)"
##############################################################################
title "3.1 PATCH /users/:id/archive → the user role soft-deletes"
patch "/users/$UID1/archive"
{ [ "$STATUS" = "200" ] || [ "$STATUS" = "204" ]; } && ok "archive ($STATUS)" || bad "archive → $STATUS"
[ -n "$(db "SELECT deleted_at FROM users WHERE id='$UID1' AND deleted_at IS NOT NULL;")" ] \
  && ok "users.deleted_at stamped (soft delete)" || bad "deleted_at not set"

title "3.2 DELETE /employees/:id → hard delete of the role; person kept (user still references it)"
delete "/employees/$EID1"
[ "$STATUS" = "200" ] || [ "$STATUS" = "204" ] && ok "employee hard delete ($STATUS)" || bad "delete → $STATUS"
[ "$(db "SELECT count(*) FROM employees WHERE id='$EID1';")" = "0" ] && ok "employee role row hard-deleted" || bad "employee row survived"
[ "$(db "SELECT count(*) FROM persons WHERE document='$DOC';")" = "1" ] \
  && ok "person KEPT — the archived user role's RESTRICT FK vetoed the orphan purge" || bad "person wrongly purged"

##############################################################################
sec "4. Probes"
##############################################################################
title "4.1 /livez static 200"
curl -sS -m 5 "$BASE/livez" | grep -q '"status":"ok"' && ok "/livez ok" || bad "/livez not ok"
title "4.2 /readyz 200 (relational SoR + Mongo answer)"
curl -sS -m 5 "$BASE/readyz" | grep -q '"status":"ready"' && ok "/readyz ready" || bad "/readyz not ready"

##############################################################################
printf '\n\033[1;36m============================================================\033[0m\n'
printf 'SQLite isolated QA — \033[1;32mPASS %d\033[0m / \033[1;31mFAIL %d\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '\033[1;32mSQLITE OK\033[0m\n' || printf '\033[1;31mSQLITE RED\033[0m\n'
exit "$FAIL"
