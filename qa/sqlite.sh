#!/usr/bin/env bash
# ============================================================================
# SQLite QA — the ISOLATED, individual run (NOT a normal lane).
#
# WHY IT IS SEPARATE (read before extending): the four run.sh lanes are each an
# engine + broker + Mongo projection pipeline, and every *.sh suite reads the
# result through the MONGO VIEW (outbox → CDC relay → broker → SyncEngine →
# Mongo). SQLite has NO CDC source (Debezium cannot tail a SQLite file), so
# Mongo-projected views never materialize on it — by design, not a bug. SQLite's
# HTTP read side (GET /users, exports, GraphQL — all go through d.ViewReader) is
# therefore EMPTY on this engine; that emptiness is itself asserted below as the
# architectural contract (section 10). SQLite is run APART:
#
#   ./qa/run.sh sqlite     → runs ONLY this isolated step (no lanes)
#   ./qa/run.sh            → runs the four DB lanes, THEN this step at the end
#
# WHAT IT EXERCISES: everything SQLite CAN do — the entire WRITE surface end to
# end over real HTTP, and its relational integrity, VERIFIED by querying the
# app.db file directly with sqlite3 (the read side that does not need a
# projection): the aggregate write (User = person + role + addresses + the
# notifications sibling), the full validation-notification vocabulary, PUT
# (strict) / PATCH (partial) / archive / unarchive, SharedBase reuse + refcount
# across roles (Employee over the same Person, its two child collections, its
# role sibling + child-level sibling), the soft-delete cascade + convergence, and
# hard delete with the savepoint orphan-purge VETO (RESTRICT FKs). It ALSO proves
# the RELATIONAL READ SIDE (RelationalSource /users-rel): SQLite's only read path
# (no CDC → the Mongo views never materialize), served straight from the SoR —
# read-your-writes, and filter/sort on shared-base (name/email/document) + root
# (userName) fields via the loader's 1:1 JOINs, with 1:N child fields + ?search=
# → 400. Boot, migrations control plane and probes are proven too. Mongo + NATS
# from the QA bench are attached only so the service boots; the Mongo-backed views
# stay empty, as expected — the relational twin is the read side that works.
#
# OUTPUT CONTRACT: like every other qa suite, it ends on the standard
# `PASS=N  FAIL=M` line (run.sh's summarize() parses it — no bespoke format).
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
BODY="/tmp/qa-sqlite.body"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { printf '\n'; hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port "$HTTP_PORT"
  rm -f "$DB_FILE" "$DB_FILE"-wal "$DB_FILE"-shm "$BODY"
}
trap cleanup EXIT INT TERM

# --- HTTP + assertion helpers ------------------------------------------------
# db <sql> — query the app.db directly (the SoR read side, no projection).
db()     { sqlite3 "$DB_FILE" "$1"; }
post()   { STATUS=$(curl -sS -m 10 -o "$BODY" -w "%{http_code}" -X POST   "$BASE$1" -H "Content-Type: application/json" --data "$2"); }
put()    { STATUS=$(curl -sS -m 10 -o "$BODY" -w "%{http_code}" -X PUT    "$BASE$1" -H "Content-Type: application/json" --data "$2"); }
patchb() { STATUS=$(curl -sS -m 10 -o "$BODY" -w "%{http_code}" -X PATCH  "$BASE$1" -H "Content-Type: application/json" --data "$2"); }
patch()  { STATUS=$(curl -sS -m 10 -o "$BODY" -w "%{http_code}" -X PATCH  "$BASE$1"); }
delete() { STATUS=$(curl -sS -m 10 -o "$BODY" -w "%{http_code}" -X DELETE "$BASE$1"); }
get()    { STATUS=$(curl -sS -m 10 -o "$BODY" -w "%{http_code}" "$BASE$1"); }
jsonq()  { python3 -c "import sys,json; d=json.load(open('$BODY')); print($1)" 2>/dev/null; }

# eq <label> <got> <want> — value assertion with a helpful diff on failure.
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi; }
# status_is <label> <want> — assert the last HTTP $STATUS; dumps the body on miss.
status_is() { if [ "$STATUS" = "$2" ]; then ok "$1 ($STATUS)"; else bad "$1 (got $STATUS want $2)"; head -c 240 "$BODY" 2>/dev/null; echo; fi; }
# status_2xx <label> — accept 200 or 204 (verbs that answer either).
status_2xx() { case "$STATUS" in 200|204) ok "$1 ($STATUS)";; *) bad "$1 (got $STATUS want 200/204)"; head -c 240 "$BODY" 2>/dev/null; echo;; esac; }
# note_has <label> <notificationKey> — assert the error envelope carries the key.
note_has() { if grep -q "\"notificationKey\":\"$2\"" "$BODY"; then ok "$1 ($2)"; else bad "$1 (no $2 in body)"; head -c 240 "$BODY" 2>/dev/null; echo; fi; }
# nn <col> <table> <where> — "SET" if the column is non-NULL, else "NULL".
nn() { db "SELECT CASE WHEN $1 IS NULL THEN 'NULL' ELSE 'SET' END FROM $2 WHERE $3 LIMIT 1;"; }

##############################################################################
sec "0. Build (CGO_ENABLED=0, -tags 'sqlite nats') + boot infra as SoR"
##############################################################################
title "0.1 Static build with the pure-Go sqlite engine"
rm -f "$DB_FILE" "$DB_FILE"-wal "$DB_FILE"-shm
if CGO_ENABLED=0 go build -tags 'sqlite nats' -o "$SERVER_BIN" ./bootstrap; then
  ok "CGO_ENABLED=0 static build with -tags 'sqlite nats'"
else
  bad "build failed"; printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"; exit 1
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
  kill -0 "$SERVER_PID" 2>/dev/null || { bad "server exited during boot — see $SERVER_LOG"; tail -20 "$SERVER_LOG"; printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"; exit 1; }
  sleep 0.5
done
[ "$ready" = ok ] && ok "service ready on SQLite (readyz 200)" || { bad "service never became ready"; tail -20 "$SERVER_LOG"; printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"; exit 1; }

title "0.4 The .db file was created + control plane + full domain schema migrated"
[ -f "$DB_FILE" ] && ok "app.db created ($DB_FILE)" || bad "app.db missing"
eq "framework control plane migrated (outbox table present)" \
  "$(db "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='outbox';")" "1"
# Every domain table from migrations/sqlite/0001 must exist (9 tables: the flat
# User aggregate + the Employee role graph + their siblings).
DOMAIN_TABLES="persons addresses users user_configurations employees employee_bank_accounts employee_dependents dependent_health_plans employee_job_histories"
missing=""
for t in $DOMAIN_TABLES; do
  [ "$(db "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='$t';")" = "1" ] || missing="$missing $t"
done
[ -z "$missing" ] && ok "all 9 domain tables migrated" || bad "missing domain tables:$missing"
# 0002 added the revision token column the framework requires (v0.36+); its
# presence proves the SECOND migration ran, not just the first.
eq "migration 0002 applied (persons.revision column present)" \
  "$(db "SELECT count(*) FROM pragma_table_info('persons') WHERE name='revision';")" "1"

##############################################################################
sec "1. Aggregate write (User = person + role + addresses + notifications)"
##############################################################################
DOC="90000000001"
title "1.1 POST /users (2 addresses, notification flags) → 201"
post /users "{\"name\":\"Sqlite One\",\"email\":\"sqlite1@example.com\",\"phone\":\"14155550001\",\"document\":\"$DOC\",\"userName\":\"sqlite1\",\"emailNotification\":true,\"smsNotification\":false,\"addresses\":[{\"label\":\"home\",\"street\":\"Rua A\",\"number\":\"1\",\"neighborhood\":\"Centro\",\"city\":\"POA\",\"state\":\"RS\",\"zipCode\":\"90000000\",\"country\":\"BR\"},{\"label\":\"work\",\"street\":\"Rua B\",\"number\":\"2\",\"neighborhood\":\"Centro\",\"city\":\"POA\",\"state\":\"RS\",\"zipCode\":\"90000001\",\"country\":\"BR\"}]}"
status_is "POST /users" 201
UID1=$(jsonq "d['data']['id']")

title "1.2 the aggregate landed in the .db (person + role + children + sibling)"
eq "persons row written" "$(db "SELECT count(*) FROM persons WHERE document='$DOC';")" "1"
eq "users role row written (shared PK)" "$(db "SELECT count(*) FROM users WHERE id='$UID1';")" "1"
eq "two address child rows written" "$(db "SELECT count(*) FROM addresses WHERE person_id='$UID1' AND deleted_at IS NULL;")" "2"
eq "user_configurations sibling row written" "$(db "SELECT count(*) FROM user_configurations WHERE id='$UID1';")" "1"

title "1.3 columns round-trip through the SQLite affinities"
eq "TEXT column round-trips exactly (user_name)" "$(db "SELECT user_name FROM users WHERE id='$UID1';")" "sqlite1"
eq "BOOLEAN→INTEGER true stored as 1 (email_notification)" "$(db "SELECT email_notification FROM user_configurations WHERE id='$UID1';")" "1"
eq "BOOLEAN→INTEGER false stored as 0 (sms_notification)" "$(db "SELECT sms_notification FROM user_configurations WHERE id='$UID1';")" "0"
eq "phone persisted" "$(db "SELECT phone FROM persons WHERE id='$UID1';")" "14155550001"
eq "TIMESTAMP default populated (created_at not null)" "$(nn created_at persons "id='$UID1'")" "SET"
eq "revision token initialized (>=0)" "$([ "$(db "SELECT revision FROM persons WHERE id='$UID1';")" -ge 0 ] && echo ok)" "ok"

title "1.4 nullable columns: omitted phone → NULL (framework never invents a value)"
post /users "{\"name\":\"No Phone\",\"email\":\"nophone@example.com\",\"document\":\"90000000010\",\"userName\":\"nophone\",\"addresses\":[{\"street\":\"S\",\"number\":\"1\",\"neighborhood\":\"N\",\"city\":\"C\",\"state\":\"RS\",\"zipCode\":\"90000000\",\"country\":\"BR\"}]}"
status_is "POST /users (no phone)" 201
UID_NP=$(jsonq "d['data']['id']")
eq "persons.phone IS NULL (omitted → NULL, not empty string)" "$(nn phone persons "id='$UID_NP'")" "NULL"
eq "addresses.label IS NULL (omitted optional child field)" "$(nn label addresses "person_id='$UID_NP'")" "NULL"
delete "/users/$UID_NP" >/dev/null 2>&1

##############################################################################
sec "2. POST /users — validation notifications (write-side, pre-persistence)"
##############################################################################
# These never reach the DB (validation runs in the domain layer before any
# INSERT), so they are engine-independent — but running them on SQLite proves the
# whole pipeline (bind → validate → envelope) works on this engine. Baseline the
# persons count so we can prove NOTHING leaked into the .db afterwards.
LEAK_BEFORE=$(db "SELECT count(*) FROM persons;")
ADDR='[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"SF","state":"CA","zipCode":"94103","country":"US"}]'
title "2.1 InvalidEmailNotification — three shapes → 422"
post /users "{\"name\":\"T\",\"email\":\"not-an-email\",\"document\":\"90000000901\",\"userName\":\"t1\",\"addresses\":$ADDR}";  status_is "no @" 422; note_has "carries InvalidEmail" "InvalidEmailNotification"
post /users "{\"name\":\"T\",\"email\":\"jane@example\",\"document\":\"90000000902\",\"userName\":\"t2\",\"addresses\":$ADDR}";  status_is "no TLD" 422
post /users "{\"name\":\"T\",\"email\":\"@example.com\",\"document\":\"90000000903\",\"userName\":\"t3\",\"addresses\":$ADDR}";  status_is "empty local-part" 422
title "2.2 InvalidPhoneNotification (too short) → 422"
post /users "{\"name\":\"T\",\"email\":\"jane@example.com\",\"phone\":\"12345\",\"document\":\"90000000904\",\"userName\":\"t4\",\"addresses\":$ADDR}"; status_is "phone too short" 422
title "2.3 Address shape rules → 422 (state / zip / country)"
post /users "{\"name\":\"T\",\"email\":\"jane@example.com\",\"document\":\"90000000905\",\"userName\":\"t5\",\"addresses\":[{\"street\":\"Main\",\"number\":\"1\",\"neighborhood\":\"D\",\"city\":\"SF\",\"state\":\"@#\",\"zipCode\":\"94103\",\"country\":\"US\"}]}"; status_is "forbidden chars in state" 422
post /users "{\"name\":\"T\",\"email\":\"jane@example.com\",\"document\":\"90000000906\",\"userName\":\"t6\",\"addresses\":[{\"street\":\"Main\",\"number\":\"1\",\"neighborhood\":\"D\",\"city\":\"SF\",\"state\":\"CA\",\"zipCode\":\"94103!\",\"country\":\"US\"}]}"; status_is "forbidden chars in zip" 422
post /users "{\"name\":\"T\",\"email\":\"jane@example.com\",\"document\":\"90000000907\",\"userName\":\"t7\",\"addresses\":[{\"street\":\"Main\",\"number\":\"1\",\"neighborhood\":\"D\",\"city\":\"SF\",\"state\":\"CA\",\"zipCode\":\"94103\",\"country\":\"\"}]}"; status_is "empty country" 422
title "2.4 DuplicateAddressNotification (Country+ZIP+Street+Number repeated) → 422"
post /users "{\"name\":\"T\",\"email\":\"jane@example.com\",\"document\":\"90000000908\",\"userName\":\"t8\",\"addresses\":[{\"street\":\"Main\",\"number\":\"1\",\"neighborhood\":\"D\",\"city\":\"SF\",\"state\":\"CA\",\"zipCode\":\"94103\",\"country\":\"US\"},{\"street\":\"Main\",\"number\":\"1\",\"neighborhood\":\"M\",\"city\":\"SF\",\"state\":\"CA\",\"zipCode\":\"94103\",\"country\":\"US\"}]}"; status_is "duplicate address" 422; note_has "carries DuplicateAddress" "DuplicateAddressNotification"
title "2.5 RequiredFieldNotification (no name) → 422"
post /users "{\"email\":\"jane@example.com\",\"document\":\"90000000909\",\"userName\":\"t9\",\"addresses\":$ADDR}"; status_is "missing name" 422
title "2.6 Multiple notifications grouped (invalid email + invalid zip) → 422"
post /users "{\"name\":\"T\",\"email\":\"x\",\"document\":\"90000000910\",\"userName\":\"t10\",\"addresses\":[{\"street\":\"Main\",\"number\":\"1\",\"neighborhood\":\"D\",\"city\":\"SF\",\"state\":\"CA\",\"zipCode\":\"!\",\"country\":\"US\"}]}"; status_is "grouped notifications" 422
title "2.7 Invalid JSON (parse error) → 400"
post /users '{not json'; status_is "malformed body" 400
title "2.8 NameMaxLengthExceededNotification — 101-char name → 422 + parameterized message"
NAME_OVER=$(python3 -c "print('A'*101)")
post /users "{\"name\":\"$NAME_OVER\",\"email\":\"jane@example.com\",\"document\":\"90000000911\",\"userName\":\"t11\",\"addresses\":$ADDR}"
status_is "over-limit name" 422
note_has "carries NameMaxLengthExceeded" "NameMaxLengthExceededNotification"
{ grep -q '100' "$BODY" && ! grep -q '{maxLength}' "$BODY"; } && ok "message substitutes the runtime limit (100, no leaked {maxLength})" || bad "parameterized message not substituted"
title "2.9 none of the rejected writes leaked into the .db"
eq "persons count unchanged after 11 invalid POSTs" "$(db "SELECT count(*) FROM persons;")" "$LEAK_BEFORE"

##############################################################################
sec "3. PUT /users/:id — strict full-body replacement"
##############################################################################
REV_BEFORE=$(db "SELECT revision FROM persons WHERE id='$UID1';")
title "3.1 PUT full body → 200 + fields replaced in the .db"
put "/users/$UID1" "{\"name\":\"Sqlite One Edited\",\"email\":\"sqlite1.edit@example.com\",\"phone\":\"14155550999\",\"userName\":\"sqlite1e\",\"emailNotification\":false,\"smsNotification\":true,\"addresses\":[{\"label\":\"home\",\"street\":\"Rua Nova\",\"number\":\"200\",\"neighborhood\":\"Centro\",\"city\":\"POA\",\"state\":\"RS\",\"zipCode\":\"90000099\",\"country\":\"BR\"}]}"
status_is "PUT /users" 200
eq "name replaced (base)" "$(db "SELECT name FROM persons WHERE id='$UID1';")" "Sqlite One Edited"
eq "email replaced (base)" "$(db "SELECT email FROM persons WHERE id='$UID1';")" "sqlite1.edit@example.com"
eq "phone replaced (base)" "$(db "SELECT phone FROM persons WHERE id='$UID1';")" "14155550999"
eq "userName replaced (role)" "$(db "SELECT user_name FROM users WHERE id='$UID1';")" "sqlite1e"
eq "notification flags upserted (email now 0)" "$(db "SELECT email_notification FROM user_configurations WHERE id='$UID1';")" "0"
eq "address collection replaced (exactly 1 active, new street)" "$(db "SELECT street FROM addresses WHERE person_id='$UID1' AND deleted_at IS NULL;")" "Rua Nova"
eq "active address count is 1 (the two originals removed)" "$(db "SELECT count(*) FROM addresses WHERE person_id='$UID1' AND deleted_at IS NULL;")" "1"
eq "revision advanced by the write" "$([ "$(db "SELECT revision FROM persons WHERE id='$UID1';")" -gt "$REV_BEFORE" ] && echo ok)" "ok"

title "3.2 PUT strict — a missing exported field is rejected with 400"
put "/users/$UID1" "{\"name\":\"X\",\"email\":\"sqlite1.edit@example.com\",\"userName\":\"sqlite1e\",\"emailNotification\":false,\"smsNotification\":true,\"addresses\":[{\"street\":\"Rua Nova\",\"number\":\"200\",\"neighborhood\":\"Centro\",\"city\":\"POA\",\"state\":\"RS\",\"zipCode\":\"90000099\",\"country\":\"BR\"}]}"
status_is "PUT without phone" 400; note_has "carries RequiredField" "RequiredFieldNotification"
put "/users/$UID1" "{\"name\":\"X\",\"email\":\"sqlite1.edit@example.com\",\"phone\":\"14155550999\",\"userName\":\"sqlite1e\",\"emailNotification\":false,\"smsNotification\":true}"
status_is "PUT without addresses" 400
put "/users/$UID1" "{\"name\":\"X\",\"email\":\"sqlite1.edit@example.com\",\"phone\":\"14155550999\",\"userName\":\"sqlite1e\",\"addresses\":[{\"street\":\"Rua Nova\",\"number\":\"200\",\"neighborhood\":\"Centro\",\"city\":\"POA\",\"state\":\"RS\",\"zipCode\":\"90000099\",\"country\":\"BR\"}]}"
status_is "PUT without notification flags" 400
title "3.3 PUT — type mismatch, malformed JSON, missing target"
put "/users/$UID1" "{\"name\":123,\"email\":\"sqlite1.edit@example.com\",\"phone\":\"1\",\"userName\":\"x\",\"emailNotification\":false,\"smsNotification\":false,\"addresses\":$ADDR}"
status_is "PUT type mismatch (name:number)" 400
put "/users/$UID1" '{not json'; status_is "PUT malformed JSON" 400
put "/users/00000000-0000-0000-0000-000000000000" "{\"name\":\"X\",\"email\":\"x@x.com\",\"phone\":\"1\",\"userName\":\"x\",\"emailNotification\":false,\"smsNotification\":false,\"addresses\":$ADDR}"
status_is "PUT nonexistent id" 404; note_has "carries RecordNotFound" "RecordNotFoundNotification"

##############################################################################
sec "4. PATCH /users/:id — partial (lenient) update"
##############################################################################
title "4.1 PATCH name only → 200; other fields preserved in the .db"
patchb "/users/$UID1" '{"name":"Sqlite One Patched"}'
status_is "PATCH name only" 200
eq "name changed" "$(db "SELECT name FROM persons WHERE id='$UID1';")" "Sqlite One Patched"
eq "email preserved (not in body)" "$(db "SELECT email FROM persons WHERE id='$UID1';")" "sqlite1.edit@example.com"
eq "phone preserved (not in body)" "$(db "SELECT phone FROM persons WHERE id='$UID1';")" "14155550999"
title "4.2 PATCH empty body → 200 noop"
ACOUNT_BEFORE=$(db "SELECT count(*) FROM addresses WHERE person_id='$UID1' AND deleted_at IS NULL;")
patchb "/users/$UID1" '{}'; status_is "PATCH empty body" 200
title "4.3 PATCH does not touch the address collection"
eq "active address count unchanged by PATCH" "$(db "SELECT count(*) FROM addresses WHERE person_id='$UID1' AND deleted_at IS NULL;")" "$ACOUNT_BEFORE"
title "4.4 PATCH invalid email → 422; nonexistent → 404"
patchb "/users/$UID1" '{"email":"nope"}'; status_is "PATCH invalid email" 422; note_has "carries InvalidEmail" "InvalidEmailNotification"
patchb "/users/00000000-0000-0000-0000-000000000000" '{"name":"X"}'; status_is "PATCH nonexistent id" 404

##############################################################################
sec "5. Archive / unarchive — aggregate-aware soft delete (base cascade)"
##############################################################################
# A user-only identity (no other role), so archiving the last role converges the
# shared Person base too — the deterministic cascade to assert.
DOC5="90000000050"
post /users "{\"name\":\"Arch Me\",\"email\":\"arch@example.com\",\"document\":\"$DOC5\",\"userName\":\"archme\",\"addresses\":[{\"street\":\"S\",\"number\":\"1\",\"neighborhood\":\"N\",\"city\":\"C\",\"state\":\"RS\",\"zipCode\":\"90000000\",\"country\":\"BR\"}]}"
UID5=$(jsonq "d['data']['id']")
title "5.1 PATCH /:id/archive → role + addresses + base all soft-deleted"
patch "/users/$UID5/archive"; status_2xx "archive"
eq "users.deleted_at stamped" "$(nn deleted_at users "id='$UID5'")" "SET"
eq "addresses.deleted_at cascaded" "$(nn deleted_at addresses "person_id='$UID5'")" "SET"
eq "persons.deleted_at converged (last role archived → base hides)" "$(nn deleted_at persons "id='$UID5'")" "SET"
title "5.2 PATCH /:id/unarchive → the whole aggregate restored"
patch "/users/$UID5/unarchive"; status_2xx "unarchive"
eq "users.deleted_at cleared" "$(nn deleted_at users "id='$UID5'")" "NULL"
eq "addresses.deleted_at cleared" "$(nn deleted_at addresses "person_id='$UID5'")" "NULL"
eq "persons.deleted_at cleared" "$(nn deleted_at persons "id='$UID5'")" "NULL"
title "5.3 unarchive on an ACTIVE record → 404 (only archived rows are visible to it)"
patch "/users/$UID5/unarchive"; status_is "unarchive active" 404
title "5.4 archive a nonexistent id → 404"
patch "/users/00000000-0000-0000-0000-000000000000/archive"; status_is "archive nonexistent" 404
delete "/users/$UID5" >/dev/null 2>&1

##############################################################################
sec "6. SharedBase — Employee role over the SAME Person"
##############################################################################
DOC6="90000000060"
title "6.1 POST /users then POST /employees on the same document → one shared Person"
post /users "{\"name\":\"Dual Role\",\"email\":\"dual@example.com\",\"document\":\"$DOC6\",\"userName\":\"dual\"}"
status_is "POST /users" 201; U6=$(jsonq "d['data']['id']")
post /employees "{\"name\":\"Dual Role\",\"email\":\"dual@example.com\",\"document\":\"$DOC6\",\"employeeNumber\":\"EMP-D1\"}"
status_is "POST /employees (same document)" 201; E6=$(jsonq "d['data']['id']")
eq "shared PK across roles (users.id == employees.id == UUIDv5(document))" "$U6" "$E6"
eq "exactly ONE persons row backs both roles" "$(db "SELECT count(*) FROM persons WHERE document='$DOC6';")" "1"
eq "users role row present" "$(db "SELECT count(*) FROM users WHERE id='$U6';")" "1"
eq "employees role row present" "$(db "SELECT count(*) FROM employees WHERE id='$E6';")" "1"

title "6.2 POST full Employee — role sibling + two child collections + child-level sibling"
DOC6B="90000000061"
BODY_FULL="{\"name\":\"Alice Pereira\",\"email\":\"alice.emp@example.com\",\"phone\":\"14155552671\",\"document\":\"$DOC6B\",\"employeeNumber\":\"EMP-0002\",\"bank\":\"260\",\"branch\":\"0001\",\"account\":\"1234567-8\",\"pix\":\"alice.emp@example.com\",\"addresses\":[{\"street\":\"1 Loop\",\"number\":\"1\",\"neighborhood\":\"M\",\"city\":\"Cupertino\",\"state\":\"CA\",\"zipCode\":\"95014\",\"country\":\"US\"}],\"dependents\":[{\"name\":\"Maria Silva\",\"birthDate\":\"2015-03-10T00:00:00Z\",\"relationship\":\"daughter\",\"healthPlanProvider\":\"Unimed\",\"healthPlanCard\":\"UN-889923\",\"healthPlanExpiry\":\"2027-12-31T00:00:00Z\"},{\"name\":\"Pedro Silva\",\"birthDate\":\"2018-07-22T00:00:00Z\",\"relationship\":\"son\"}],\"jobHistories\":[{\"jobTitle\":\"Engineer\",\"department\":\"Platform\",\"hiredAt\":\"2022-01-10T00:00:00Z\"},{\"jobTitle\":\"Analyst\",\"department\":\"Data\",\"hiredAt\":\"2019-05-01T00:00:00Z\",\"terminatedAt\":\"2021-12-31T00:00:00Z\"}]}"
post /employees "$BODY_FULL"
status_is "POST full employee" 201; E6B=$(jsonq "d['data']['id']")
eq "employee role row" "$(db "SELECT count(*) FROM employees WHERE id='$E6B';")" "1"
eq "role sibling (employee_bank_accounts) row" "$(db "SELECT count(*) FROM employee_bank_accounts WHERE id='$E6B';")" "1"
eq "bank account fields persisted" "$(db "SELECT account FROM employee_bank_accounts WHERE id='$E6B';")" "1234567-8"
eq "two dependents (role child collection)" "$(db "SELECT count(*) FROM employee_dependents WHERE employee_id='$E6B' AND deleted_at IS NULL;")" "2"
eq "one dependent health plan (CHILD-level sibling)" "$(db "SELECT count(*) FROM dependent_health_plans p JOIN employee_dependents d ON p.id=d.id WHERE d.employee_id='$E6B';")" "1"
eq "health plan provider persisted" "$(db "SELECT provider FROM dependent_health_plans p JOIN employee_dependents d ON p.id=d.id WHERE d.employee_id='$E6B';")" "Unimed"
eq "two job histories (role child collection)" "$(db "SELECT count(*) FROM employee_job_histories WHERE employee_id='$E6B' AND deleted_at IS NULL;")" "2"

##############################################################################
sec "7. SharedBase conflict — re-adding an ACTIVE role is a 409"
##############################################################################
title "7.1 re-POST /users for a document that already has an active user → 409"
post /users "{\"name\":\"Dual Role\",\"email\":\"dual@example.com\",\"document\":\"$DOC6\",\"userName\":\"dual2\"}"
status_is "duplicate active user" 409; note_has "carries EntityAlreadyAdded" "EntityAlreadyAddedNotification"
title "7.2 re-POST /employees for a document that already has an active employee → 409"
post /employees "{\"name\":\"Dual Role\",\"email\":\"dual@example.com\",\"document\":\"$DOC6\",\"employeeNumber\":\"EMP-D2\"}"
status_is "duplicate active employee" 409; note_has "carries EntityAlreadyAdded" "EntityAlreadyAddedNotification"

# 7.3 — the ARCHIVED-remnant conflict: an archived role is invisible to the
# framework's active-role probe (DeletedAt is delete), so the insert falls
# through to the PRIMARY KEY and the repository's ConstraintBinding maps that
# UNIQUE violation to the SAME 409. On SQLite the violated key is the COLUMN LIST
# (`users.id` / `employees.id`) — NOT a constraint name like the other engines —
# so this only reaches 409 (vs a leaked 500) because those SQLite keys are
# registered in the binding maps (user_repository.go / employee_repository.go).
# Re-POST with NO address so the PK remnant is the ONLY conflict (a re-sent
# address would trip DuplicateAddress 422 first, on the archived person's rows).
title "7.3 re-POST an ARCHIVED user's document → 409 (constraint-binding layer)"
DOC7U="90000000070"
post /users "{\"name\":\"Arc U\",\"email\":\"arcu@example.com\",\"document\":\"$DOC7U\",\"userName\":\"arcu\"}"; A7U=$(jsonq "d['data']['id']")
patch "/users/$A7U/archive"; status_2xx "archive the user first"
post /users "{\"name\":\"Arc U\",\"email\":\"arcu@example.com\",\"document\":\"$DOC7U\",\"userName\":\"arcu2\"}"
status_is "re-POST archived user (PK remnant → 409, not 500)" 409; note_has "carries EntityAlreadyAdded" "EntityAlreadyAddedNotification"
patch "/users/$A7U/unarchive" >/dev/null 2>&1; delete "/users/$A7U" >/dev/null 2>&1
title "7.4 re-POST an ARCHIVED employee's document → 409 (constraint-binding layer)"
DOC7E="90000000071"
post /employees "{\"name\":\"Arc E\",\"email\":\"arce@example.com\",\"document\":\"$DOC7E\",\"employeeNumber\":\"EMP-A7\"}"; A7E=$(jsonq "d['data']['id']")
patch "/employees/$A7E/archive"; status_2xx "archive the employee first"
post /employees "{\"name\":\"Arc E\",\"email\":\"arce@example.com\",\"document\":\"$DOC7E\",\"employeeNumber\":\"EMP-A8\"}"
status_is "re-POST archived employee (PK remnant → 409, not 500)" 409; note_has "carries EntityAlreadyAdded" "EntityAlreadyAddedNotification"
patch "/employees/$A7E/unarchive" >/dev/null 2>&1; delete "/employees/$A7E" >/dev/null 2>&1

##############################################################################
sec "8. Hard delete + orphan-purge VETO (savepoint + RESTRICT FKs)"
##############################################################################
title "8.1 DELETE one role while another is active → role gone, Person KEPT (FK veto)"
# DOC6 has BOTH a user and an employee. Deleting the user must NOT purge the
# person: the employee's RESTRICT FK to persons vetoes the orphan purge under a
# savepoint, and the user delete still commits. This is the SQLite proof that
# PRAGMA foreign_keys is ON in the app (RESTRICT has teeth).
delete "/users/$U6"; status_2xx "DELETE /users (employee still active)"
eq "user role row hard-deleted" "$(db "SELECT count(*) FROM users WHERE id='$U6';")" "0"
eq "employee role row kept" "$(db "SELECT count(*) FROM employees WHERE id='$E6';")" "1"
eq "person KEPT — RESTRICT FK from the live employee vetoed the purge" "$(db "SELECT count(*) FROM persons WHERE document='$DOC6';")" "1"
title "8.2 DELETE the LAST role → Person purged, children cascade away"
delete "/employees/$E6"; status_2xx "DELETE /employees (last role)"
eq "employee role row hard-deleted" "$(db "SELECT count(*) FROM employees WHERE id='$E6';")" "0"
eq "person purged (no role references it)" "$(db "SELECT count(*) FROM persons WHERE document='$DOC6';")" "0"
eq "addresses cascade-deleted with the person (ON DELETE CASCADE)" "$(db "SELECT count(*) FROM addresses WHERE person_id='$U6';")" "0"
title "8.3 DELETE a nonexistent id → 404"
delete "/users/00000000-0000-0000-0000-000000000000"; status_is "DELETE nonexistent" 404
title "8.4 DELETE the full employee → its two child collections + siblings cascade"
delete "/employees/$E6B"; status_2xx "DELETE full employee"
eq "dependents gone" "$(db "SELECT count(*) FROM employee_dependents WHERE employee_id='$E6B';")" "0"
eq "health plans gone (grandchild cascade)" "$(db "SELECT count(*) FROM dependent_health_plans;")" "0"
eq "job histories gone" "$(db "SELECT count(*) FROM employee_job_histories WHERE employee_id='$E6B';")" "0"
eq "bank account sibling gone" "$(db "SELECT count(*) FROM employee_bank_accounts WHERE id='$E6B';")" "0"

##############################################################################
sec "9. Employee archive cascade to role children"
##############################################################################
DOC9="90000000090"
post /employees "{\"name\":\"Cascade\",\"email\":\"cascade@example.com\",\"document\":\"$DOC9\",\"employeeNumber\":\"EMP-C9\",\"dependents\":[{\"name\":\"Kid\",\"birthDate\":\"2016-01-01T00:00:00Z\",\"relationship\":\"son\"}],\"jobHistories\":[{\"jobTitle\":\"Dev\",\"department\":\"Eng\",\"hiredAt\":\"2020-01-01T00:00:00Z\"}]}"
E9=$(jsonq "d['data']['id']")
title "9.1 archive employee → role children soft-delete alongside the role"
patch "/employees/$E9/archive"; status_2xx "archive employee"
eq "employee.deleted_at stamped" "$(nn deleted_at employees "id='$E9'")" "SET"
eq "dependent.deleted_at cascaded" "$(nn deleted_at employee_dependents "employee_id='$E9'")" "SET"
eq "job history.deleted_at cascaded" "$(nn deleted_at employee_job_histories "employee_id='$E9'")" "SET"
title "9.2 unarchive employee → children restored"
patch "/employees/$E9/unarchive"; status_2xx "unarchive employee"
eq "dependent.deleted_at cleared" "$(nn deleted_at employee_dependents "employee_id='$E9'")" "NULL"
delete "/employees/$E9" >/dev/null 2>&1

##############################################################################
sec "10. Manual showcase (/showcase/users-custom, keyed by document)"
##############################################################################
# The hand-rolled command/query chain over the SAME users/persons tables — proves
# the manual orchestration path works on SQLite AND exercises the third
# constraint-binding map (user_custom_repository.go). Identifier is the document.
DOCM="90000000200"
title "10.1 POST /showcase/users-custom → 201, lands in the shared tables"
post /showcase/users-custom "{\"name\":\"Manual\",\"email\":\"manual@example.com\",\"document\":\"$DOCM\",\"userName\":\"manual\",\"addresses\":[{\"street\":\"S\",\"number\":\"1\",\"neighborhood\":\"N\",\"city\":\"C\",\"state\":\"RS\",\"zipCode\":\"90000000\",\"country\":\"BR\"}]}"
status_is "POST manual" 201
eq "user row written via the manual path (shared users/persons tables)" "$(db "SELECT count(*) FROM users u JOIN persons p ON u.id=p.id WHERE p.document='$DOCM';")" "1"
title "10.2 re-POST an active document → 409 (manual surface's conflict envelope)"
post /showcase/users-custom "{\"name\":\"Manual\",\"email\":\"manual@example.com\",\"document\":\"$DOCM\",\"userName\":\"manual2\"}"
status_is "duplicate active (manual)" 409; note_has "carries EntityAlreadyAdded" "EntityAlreadyAddedNotification"
title "10.3 archive (manual) then re-POST the archived document → 409 (3rd binding key)"
patch "/showcase/users-custom/$DOCM/archive"; status_2xx "archive manual"
eq "manual archive soft-deleted the user row" "$(nn deleted_at users "id=(SELECT id FROM persons WHERE document='$DOCM')")" "SET"
post /showcase/users-custom "{\"name\":\"Manual\",\"email\":\"manual@example.com\",\"document\":\"$DOCM\",\"userName\":\"manual3\"}"
status_is "re-POST archived (manual, PK remnant → 409)" 409; note_has "carries EntityAlreadyAdded" "EntityAlreadyAddedNotification"
title "10.4 GET /showcase/users-custom/:document → 404 (reads the empty Mongo view)"
patch "/showcase/users-custom/$DOCM/unarchive" >/dev/null 2>&1
get "/showcase/users-custom/$DOCM"; status_is "GET manual by document (empty view)" 404
title "10.5 DELETE /showcase/users-custom/:document → purged from the SoR"
delete "/showcase/users-custom/$DOCM"; status_2xx "DELETE manual"
eq "manual delete purged the person" "$(db "SELECT count(*) FROM persons WHERE document='$DOCM';")" "0"

##############################################################################
sec "11. PUT address collection — child-id write-back + atomic replacement"
##############################################################################
DOC11="90000000210"
post /users "{\"name\":\"Addr\",\"email\":\"addr@example.com\",\"phone\":\"14155550001\",\"document\":\"$DOC11\",\"userName\":\"addr\",\"emailNotification\":true,\"smsNotification\":true,\"addresses\":[{\"street\":\"Old St\",\"number\":\"1\",\"neighborhood\":\"N\",\"city\":\"C\",\"state\":\"RS\",\"zipCode\":\"90000000\",\"country\":\"BR\"}]}"
U11=$(jsonq "d['data']['id']")
AID_POST=$(db "SELECT id FROM addresses WHERE person_id='$U11' AND deleted_at IS NULL;")
title "11.1 PUT with a new address → 200; the response carries a FRESH child id"
put "/users/$U11" "{\"name\":\"Addr\",\"email\":\"addr@example.com\",\"phone\":\"14155550001\",\"userName\":\"addr\",\"emailNotification\":true,\"smsNotification\":true,\"addresses\":[{\"street\":\"New St\",\"number\":\"9\",\"neighborhood\":\"N\",\"city\":\"C\",\"state\":\"RS\",\"zipCode\":\"90000009\",\"country\":\"BR\"}]}"
status_is "PUT replace address" 200
AID_PUT=$(jsonq "d['data']['addresses'][0]['id']")
eq "write-back: new address id is a 36-char UUID" "${#AID_PUT}" "36"
eq "write-back: new address id differs from the POST-time id" "$([ "$AID_PUT" != "$AID_POST" ] && echo differ)" "differ"
title "11.2 the .db reflects the atomic collection replacement"
eq "exactly one ACTIVE address after replace" "$(db "SELECT count(*) FROM addresses WHERE person_id='$U11' AND deleted_at IS NULL;")" "1"
eq "the active address is the NEW one" "$(db "SELECT street FROM addresses WHERE person_id='$U11' AND deleted_at IS NULL;")" "New St"
delete "/users/$U11" >/dev/null 2>&1

##############################################################################
sec "12. Notification-flags sibling — set then CLEAR via PUT null"
##############################################################################
DOC12="90000000220"
post /users "{\"name\":\"Flags\",\"email\":\"flags@example.com\",\"phone\":\"14155550001\",\"document\":\"$DOC12\",\"userName\":\"flags\",\"emailNotification\":true,\"smsNotification\":true,\"addresses\":[{\"street\":\"S\",\"number\":\"1\",\"neighborhood\":\"N\",\"city\":\"C\",\"state\":\"RS\",\"zipCode\":\"90000000\",\"country\":\"BR\"}]}"
U12=$(jsonq "d['data']['id']")
title "12.1 flags upserted the sibling row"
eq "user_configurations row present" "$(db "SELECT count(*) FROM user_configurations WHERE id='$U12';")" "1"
eq "email_notification stored true" "$(db "SELECT email_notification FROM user_configurations WHERE id='$U12';")" "1"
title "12.2 PUT with BOTH flags null → the sibling row is CLEARED (removed)"
put "/users/$U12" "{\"name\":\"Flags\",\"email\":\"flags@example.com\",\"phone\":\"14155550001\",\"userName\":\"flags\",\"emailNotification\":null,\"smsNotification\":null,\"addresses\":[{\"street\":\"S\",\"number\":\"1\",\"neighborhood\":\"N\",\"city\":\"C\",\"state\":\"RS\",\"zipCode\":\"90000000\",\"country\":\"BR\"}]}"
status_is "PUT with null flags" 200
eq "user_configurations row cleared (0 rows)" "$(db "SELECT count(*) FROM user_configurations WHERE id='$U12';")" "0"
delete "/users/$U12" >/dev/null 2>&1

##############################################################################
sec "13. created_at immutability + rebirth of a purged natural key"
##############################################################################
DOC13="90000000230"
post /users "{\"name\":\"Immutable\",\"email\":\"imm@example.com\",\"document\":\"$DOC13\",\"userName\":\"imm\"}"
U13=$(jsonq "d['data']['id']")
CREATED13=$(db "SELECT created_at FROM persons WHERE id='$U13';")
title "13.1 created_at survives an update (PATCH) untouched"
patchb "/users/$U13" '{"name":"Immutable Edited"}'; status_is "PATCH" 200
eq "persons.created_at unchanged by the update" "$(db "SELECT created_at FROM persons WHERE id='$U13';")" "$CREATED13"
title "13.2 rebirth: purge the identity then re-POST the SAME document → 201"
delete "/users/$U13"; status_2xx "DELETE (purges the last role's base)"
eq "identity fully purged" "$(db "SELECT count(*) FROM persons WHERE document='$DOC13';")" "0"
post /users "{\"name\":\"Reborn\",\"email\":\"reborn@example.com\",\"document\":\"$DOC13\",\"userName\":\"reborn\"}"
status_is "re-POST the purged document (PK remnant gone → fresh insert)" 201
eq "the reborn identity exists again (id is deterministic UUIDv5(document))" "$(db "SELECT count(*) FROM persons WHERE document='$DOC13';")" "1"
eq "reborn id equals the original (document → same UUIDv5)" "$(jsonq "d['data']['id']")" "$U13"
delete "/users/$U13" >/dev/null 2>&1

##############################################################################
sec "14. SharedBase refcount — base converges only when the LAST role archives"
##############################################################################
DOC14="90000000240"
post /users "{\"name\":\"Ref\",\"email\":\"ref@example.com\",\"document\":\"$DOC14\",\"userName\":\"ref\"}"; U14=$(jsonq "d['data']['id']")
post /employees "{\"name\":\"Ref\",\"email\":\"ref@example.com\",\"document\":\"$DOC14\",\"employeeNumber\":\"EMP-R\"}"; status_is "second role added" 201
title "14.1 archive ONE role — the shared base stays ACTIVE (the other role holds it)"
patch "/users/$U14/archive"; status_2xx "archive the user role"
eq "user role soft-deleted" "$(nn deleted_at users "id='$U14'")" "SET"
eq "employee role still active" "$(nn deleted_at employees "id='$U14'")" "NULL"
eq "persons base NOT converged (employee still references it)" "$(nn deleted_at persons "id='$U14'")" "NULL"
title "14.2 archive the LAST role — now the base converges (hides)"
patch "/employees/$U14/archive"; status_2xx "archive the employee role"
eq "persons base converged (last active role archived)" "$(nn deleted_at persons "id='$U14'")" "SET"
patch "/users/$U14/unarchive" >/dev/null 2>&1; delete "/users/$U14" >/dev/null 2>&1; delete "/employees/$U14" >/dev/null 2>&1

##############################################################################
sec "15. Employee validation + archive idempotency"
##############################################################################
title "15.1 POST /employees missing employeeNumber → 422"
post /employees '{"name":"NoNum","email":"nonum@example.com","document":"90000000250"}'
status_is "missing employeeNumber" 422
title "15.2 POST /employees invalid email → 422"
post /employees '{"name":"BadMail","email":"bad","document":"90000000251","employeeNumber":"EMP-B"}'
status_is "invalid employee email" 422
title "15.3 archiving an ALREADY-archived record → 404 (the active scope no longer sees it)"
post /users "{\"name\":\"Idem\",\"email\":\"idem@example.com\",\"document\":\"90000000252\",\"userName\":\"idem\"}"; U15=$(jsonq "d['data']['id']")
patch "/users/$U15/archive"; status_2xx "first archive"
patch "/users/$U15/archive"; status_is "re-archive already-archived" 404
patch "/users/$U15/unarchive" >/dev/null 2>&1; delete "/users/$U15" >/dev/null 2>&1

##############################################################################
sec "16. Relational read side (RelationalSource twin /users-rel) — SQLite's read path"
##############################################################################
# SQLite has no CDC, so the Mongo views never materialize (asserted in section 17).
# The users_rel view is served STRAIGHT FROM THE SoR (RelationalSource), so it is
# the read side that DOES work on SQLite — read-your-writes, zero projection lag.
# It also proves the reader's 1:1 reach on a shared-base role: name/email/document
# are Person SHARED-BASE fields, userName the role field — all filterable/sortable
# because the loader LEFT JOINs the base (and the user_configurations sibling) in.
# Self-contained: seeds its own user (UID1 has been mutated/archived by earlier
# sections) and cleans it up.
RDOC="90000000200"
post /users "{\"name\":\"Rel Read\",\"email\":\"relread@example.com\",\"phone\":\"14155550200\",\"document\":\"$RDOC\",\"userName\":\"relread\",\"emailNotification\":true,\"smsNotification\":false,\"addresses\":[{\"label\":\"home\",\"street\":\"Rua R\",\"number\":\"1\",\"neighborhood\":\"Centro\",\"city\":\"Portland\",\"state\":\"OR\",\"zipCode\":\"97000000\",\"country\":\"US\"}]}"
status_is "seed a user for the relational read" 201
RID=$(jsonq "d['data']['id']")

title "16.1 GET /users-rel/:id → 200 — the FULL aggregate reads back (root+base+sibling+base-child)"
get "/users-rel/$RID"; status_is "by-id on the relational twin" 200
eq "ROOT field (userName)"                 "$(jsonq "d['data']['userName']")" "relread"
eq "SHARED-BASE field (name)"              "$(jsonq "d['data']['name']")" "Rel Read"
eq "SHARED-BASE field (email)"             "$(jsonq "d['data']['email']")" "relread@example.com"
eq "SHARED-BASE field (document)"          "$(jsonq "d['data']['document']")" "$RDOC"
eq "SIBLING field (emailNotification=true)" "$(jsonq "d['data']['emailNotification']")" "True"
eq "SIBLING field (smsNotification=false)"  "$(jsonq "d['data']['smsNotification']")" "False"
eq "BASE-CHILD array present (1 address)"   "$(jsonq "len(d['data']['addresses'])")" "1"
eq "BASE-CHILD field (address city)"        "$(jsonq "d['data']['addresses'][0]['city']")" "Portland"

title "16.2 filter by a SHARED-BASE field — the loader LEFT JOINs persons in"
get "/users-rel?document.eq=$RDOC"; status_is "document.eq (base natural key)" 200
eq "document.eq selects exactly the seeded user" "$(jsonq "len(d['data'])")" "1"
eq "  and it is the seeded id" "$(jsonq "d['data'][0]['id']")" "$RID"
get "/users-rel?name.eq=Rel%20Read"; status_is "name.eq (base field)" 200
eq "name.eq selects 1" "$(jsonq "len(d['data'])")" "1"
get "/users-rel?email.eq=relread@example.com"; status_is "email.eq (base field)" 200
eq "email.eq selects 1 (JOIN on the base column)" "$(jsonq "len(d['data'])")" "1"

title "16.3 filter by the ROOT role field + sort by a base field (id tiebreak stays unambiguous)"
get "/users-rel?userName.eq=relread"; status_is "userName.eq (root)" 200
eq "userName.eq selects 1" "$(jsonq "len(d['data'])")" "1"
get "/users-rel?document.eq=$RDOC&sort=name"; status_is "sort by a base field is accepted (ORDER BY joined col , id)" 200
eq "sort=name still selects the seeded user" "$(jsonq "len(d['data'])")" "1"

title "16.4 a no-match base filter → empty page (200, not 404)"
get "/users-rel?document.eq=00000000000"; status_is "no-match base filter" 200
eq "no-match → empty data array" "$(jsonq "len(d['data'])")" "0"

title "16.5 unsupported on the twin → 400 RelationalCapabilityNotification"
get "/users-rel?search=rel"; status_is "?search= → 400" 400; note_has "search rejected" "RelationalCapabilityNotification"
get "/users-rel?addresses.city.eq=Portland"; status_is "1:N child filter → 400" 400; note_has "child filter rejected" "RelationalCapabilityNotification"

delete "/users/$RID" >/dev/null 2>&1

##############################################################################
sec "17. Mongo read side is EMPTY by design (no CDC → no Mongo projection)"
##############################################################################
# The Mongo-backed views (users/employees/persons) go through d.ViewReader → the
# Mongo reader, which SQLite never populates (Debezium cannot tail a .db file).
# This is not a gap to fix — it is the documented contract: SQLite serves WRITES
# to the SoR and READS via the relational twin above; its Mongo-projected views
# stay empty. We assert that positively so a future regression that silently
# starts serving stale/partial Mongo reads on SQLite is caught.
DOC10="90000000100"
post /users "{\"name\":\"Ghost\",\"email\":\"ghost@example.com\",\"document\":\"$DOC10\",\"userName\":\"ghost\"}"
G10=$(jsonq "d['data']['id']")
eq "the write DID land in the SoR (.db has the row)" "$(db "SELECT count(*) FROM users WHERE id='$G10';")" "1"
title "17.1 GET /users/:id → 404 (document never projected to Mongo)"
get "/users/$G10"; status_is "GET by id on empty view" 404; note_has "RecordNotFound" "RecordNotFoundNotification"
title "17.2 GET /users → 200 with an empty page (total 0)"
get "/users"; status_is "GET list on empty view" 200
eq "empty data array" "$(jsonq "len(d['data'])")" "0"
eq "pagination total is 0" "$(jsonq "d['pagination']['total']")" "0"
title "17.3 GET /employees and GET /persons → empty too"
get "/employees"; status_is "GET /employees" 200; eq "empty employees" "$(jsonq "len(d['data'])")" "0"
get "/persons"; status_is "GET /persons" 200; eq "empty persons" "$(jsonq "len(d['data'])")" "0"
delete "/users/$G10" >/dev/null 2>&1

##############################################################################
sec "18. Probes + write-side control plane"
##############################################################################
title "17.1 /livez static 200"
get "/livez"; { [ "$STATUS" = "200" ] && grep -q '"status":"ok"' "$BODY"; } && ok "/livez ok" || bad "/livez not ok ($STATUS)"
title "17.2 /readyz 200 (relational SoR + Mongo answer)"
get "/readyz"; { [ "$STATUS" = "200" ] && grep -q '"status":"ready"' "$BODY"; } && ok "/readyz ready" || bad "/readyz not ready ($STATUS)"
title "17.3 the outbox captured the domain writes (control-plane row present)"
eq "outbox has rows (every write emits an event row)" "$([ "$(db "SELECT count(*) FROM outbox;")" -gt 0 ] && echo ok)" "ok"

##############################################################################
printf '\n'; hr
printf 'SQLite isolated QA — \033[1;32mPASS %d\033[0m / \033[1;31mFAIL %d\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && printf '\033[1;32mSQLITE OK\033[0m\n' || printf '\033[1;31mSQLITE RED\033[0m\n'
# Standard machine-readable summary line — run.sh's summarize() parses this
# exactly as it does for every other suite (no bespoke format).
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
