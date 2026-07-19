#!/usr/bin/env bash
# End-to-end suite for the Employee aggregate — the SECOND role over the shared
# Person identity. It exists to prove the framework paths a single role cannot:
#
#   1. SharedBase reuse across roles (same document → ONE persons row, shared
#      PK on both roles), refcount-driven orphan lifecycle, the database-vetoable
#      purge (FK RESTRICT from a table the schema registry does not know), and
#      the purge's own audit event + outbox row.
#   2. TWO role-owned child collections (dependents + job histories) rendered
#      FLAT on every surface, filterable by child path.
#   3. A sibling at the CHILD level (dependent → dependent_health_plans, "A2b"):
#      conditional materialization one level down the aggregate.
#   4. The role's own sibling (employee_bank_accounts): skipped on INSERT when
#      all-nil, untouched by PATCH, removed by a PUT omitting the facet.
#   5. Archive/unarchive cascade over role children + the base's keep-by-default
#      convergence across roles.
#   6. CSV/XLSX hierarchical export incl. child + sibling columns.
#   7. The same handlers through GraphQL (query + all six mutations).
#   9-12. The CROSS-ROLE matrix: last-write-wins on shared fields with fan-out
#      in both directions, base children edited through either role, the
#      soft-delete matrix in both orders (an ARCHIVED role is invisible to a
#      re-POST — soft-delete is delete; /unarchive is the only way back), the
#      hard-delete matrix in both orders, and the archived-row refcount (an
#      archived role still blocks the purge).
#
# Dialect-driven via qa/_backend.sh (BACKEND=postgres|mysql). Needs the service
# already running on :8080 with APP_PROFILE=dev and the Debezium connector
# registered (same contract as e2e.sh).
#
# Run from anywhere:  bash qa/employee.sh
set -u

source "$(dirname "$0")/_backend.sh"

BASE="${BASE:-http://localhost:8080}"
PASS=0; FAIL=0

hr() { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec() { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()   { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# req <method> <path> [body] → sets STATUS + RESP
req() {
  local method="$1" path="$2" body="${3:-}"
  local tmp; tmp=$(mktemp)
  if [ -n "$body" ]; then
    STATUS=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" \
      -H "Content-Type: application/json" -H "Accept-Language: en-US" --data "$body")
  else
    STATUS=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" \
      -H "Content-Type: application/json" -H "Accept-Language: en-US")
  fi
  RESP=$(cat "$tmp"); rm -f "$tmp"
}

# expect_status <label> <expected>
expect_status() {
  if [ "$STATUS" = "$2" ]; then ok "$1 (status $STATUS)"; else bad "$1 (expected $2, got $STATUS) — $RESP"; fi
}

# jsonq <python-expr-on-d> — evaluates against $RESP parsed as d
jsonq() { printf '%s' "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

# wait_view_total <query-string> <expected-total> [timeout] — polls the list
# endpoint until pagination.total matches (CDC is eventually consistent).
wait_view_total() {
  local qs="$1" expected="$2" timeout="${3:-20}"
  local deadline=$(( $(date +%s) + timeout )) total
  while [ "$(date +%s)" -lt "$deadline" ]; do
    req GET "/employees?$qs&onlyTotal=true"
    total=$(jsonq "d['pagination']['total']")
    [ "$total" = "$expected" ] && return 0
    sleep 0.3
  done
  return 1
}

####################################
sec "0. Health + clean slate"
####################################
req GET /livez
expect_status "GET /livez" 200
qa_db_reset_domain
qa_mongo_reset
qa_db_exec "DELETE FROM audit_events;" 2>/dev/null || true
ok "domain tables + view collections reset"

title "0.1 CDC warm-up probe (absorbs Kafka consumer-group rebalance after a server restart)"
req POST /users '{"name":"Cdc Probe","email":"probe@example.com","document":"30000000000","userName":"cdcprobe"}'
if [ "$STATUS" = "201" ]; then
  PROBE_ID=$(jsonq "d['data']['id']")
  deadline=$(( $(date +%s) + 60 )); warm=fail
  while [ "$(date +%s)" -lt "$deadline" ]; do
    req GET "/users/$PROBE_ID"
    [ "$STATUS" = "200" ] && { warm=ok; break; }
    sleep 0.5
  done
  # Discard the probe WITHOUT app events (an app DELETE would purge the probe
  # person and pollute section 1's audit/outbox baselines): SQL + Mongo reset.
  qa_db_reset_domain
  qa_db_exec "DELETE FROM audit_events;" 2>/dev/null || true
  qa_mongo_reset
  [ "$warm" = ok ] && ok "CDC pipeline warm (probe doc materialized; state re-reset)" || bad "CDC pipeline never delivered the probe doc in 60s"
else
  bad "probe POST failed ($STATUS)"
fi

####################################
sec "1. SharedBase reuse across roles (layer 6) + vetoable purge + purge audit"
####################################
D1="30000000001"

title "1.1 POST /users (first role for document $D1)"
req POST /users "{\"name\":\"Cross Role\",\"email\":\"cross@example.com\",\"document\":\"$D1\",\"userName\":\"crossrole\"}"
expect_status "create user role" 201
UID1=$(jsonq "d['data']['id']")

title "1.2 POST /employees with the SAME document → same person, same deterministic id"
req POST /employees "{\"name\":\"Cross Role\",\"email\":\"cross@example.com\",\"document\":\"$D1\",\"employeeNumber\":\"EMP-C1\"}"
expect_status "create employee role over existing person" 201
EID1=$(jsonq "d['data']['id']")
if [ "$UID1" = "$EID1" ]; then
  ok "shared PK across roles: users.id == employees.id == UUIDv5(document) ($EID1)"
else
  bad "role ids diverge: user=$UID1 employee=$EID1"
fi

title "1.3 Exactly ONE persons row backs both roles"
PCOUNT=$(qa_db_query "SELECT count(*) FROM persons;")
[ "$PCOUNT" = "1" ] && ok "persons count = 1" || bad "persons count = $PCOUNT (want 1)"

title "1.4 Shared-field change through the EMPLOYEE fans out to the USER view"
req PATCH "/employees/$EID1" '{"name":"Cross Role Renamed"}'
expect_status "PATCH employee name (shared field)" 200
deadline=$(( $(date +%s) + 20 )); fanout=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  req GET "/users/$UID1"
  [ "$(jsonq "d['data']['name']")" = "Cross Role Renamed" ] && { fanout=ok; break; }
  sleep 0.3
done
[ "$fanout" = ok ] && ok "user view shows the name written through the employee role" \
                   || bad "user view did not converge to the shared name"

title "1.5 DELETE the USER role → person MUST survive (employee still references it)"
req DELETE "/users/$UID1"
expect_status "delete user role" 204
PCOUNT=$(qa_db_query "SELECT count(*) FROM persons;")
[ "$PCOUNT" = "1" ] && ok "person survives while employee role remains" || bad "person purged early (count=$PCOUNT)"
PURGE_AUDIT=$(qa_db_query "SELECT count(*) FROM audit_events WHERE entity_type='persons' AND verb='delete';")
[ "$PURGE_AUDIT" = "0" ] && ok "no persons purge audit event yet" || bad "unexpected persons purge audit rows: $PURGE_AUDIT"

title "1.6 FK RESTRICT veto: an UNREGISTERED table referencing the person blocks the purge"
# Per-dialect id type + veto clause (T-SQL spells RESTRICT as NO ACTION;
# Oracle has NO explicit spelling — omitting ON DELETE IS the restrict default).
case "$BACKEND" in
  postgres) QA_REF_TYPE='UUID';       QA_REF_FK_TAIL=' ON DELETE RESTRICT' ;;
  oracle)   QA_REF_TYPE='RAW(16)';    QA_REF_FK_TAIL='' ;;
  *)        QA_REF_TYPE='BINARY(16)'; QA_REF_FK_TAIL=' ON DELETE NO ACTION' ;;
esac
qa_db_exec "CREATE TABLE qa_external_refs (person_id $QA_REF_TYPE NOT NULL, CONSTRAINT fk_qa_external_refs_person FOREIGN KEY (person_id) REFERENCES persons (id)$QA_REF_FK_TAIL);" 2>/dev/null \
  || qa_db_exec "CREATE TABLE qa_external_refs (person_id UUID NOT NULL REFERENCES persons (id) ON DELETE RESTRICT);"
qa_db_exec "INSERT INTO qa_external_refs (person_id) SELECT id FROM persons;"
req DELETE "/employees/$EID1"
expect_status "delete LAST role (purge attempted, must be vetoed)" 204
PCOUNT=$(qa_db_query "SELECT count(*) FROM persons;")
ECOUNT=$(qa_db_query "SELECT count(*) FROM employees;")
if [ "$PCOUNT" = "1" ] && [ "$ECOUNT" = "0" ]; then
  ok "veto honored: role delete committed, person stayed"
else
  bad "veto broken: persons=$PCOUNT employees=$ECOUNT (want 1/0)"
fi
PURGE_AUDIT=$(qa_db_query "SELECT count(*) FROM audit_events WHERE entity_type='persons' AND verb='delete';")
[ "$PURGE_AUDIT" = "0" ] && ok "vetoed purge emitted NO persons audit event" || bad "vetoed purge emitted audit rows: $PURGE_AUDIT"

title "1.7 Drop the external ref, re-create the employee role (kept identity is reused)"
qa_db_exec "DROP TABLE qa_external_refs;"
req POST /employees "{\"name\":\"Cross Role Renamed\",\"email\":\"cross@example.com\",\"document\":\"$D1\",\"employeeNumber\":\"EMP-C1\"}"
expect_status "re-create employee over the kept person" 201
[ "$(jsonq "d['data']['id']")" = "$EID1" ] && ok "same deterministic id reused" || bad "id changed on re-create"

title "1.8 DELETE the last role with no external refs → REAL purge + audit + outbox"
req DELETE "/employees/$EID1"
expect_status "delete last role (real purge)" 204
PCOUNT=$(qa_db_query "SELECT count(*) FROM persons;")
[ "$PCOUNT" = "0" ] && ok "person physically purged (DeleteWhenUnreferenced)" || bad "person still present (count=$PCOUNT)"
PURGE_AUDIT=$(qa_db_query "SELECT count(*) FROM audit_events WHERE entity_type='persons' AND verb='delete' AND kind='snapshot';")
[ "$PURGE_AUDIT" = "1" ] && ok "purge emitted its own audit event (entity_type=persons, kind=snapshot)" \
                         || bad "persons purge audit rows = $PURGE_AUDIT (want 1)"
PURGE_OUTBOX=$(qa_db_query "SELECT count(*) FROM outbox WHERE aggregate_type='persons' AND event_type='DELETED';")
[ "$PURGE_OUTBOX" = "1" ] && ok "purge emitted its own DELETED outbox row for the base" \
                          || bad "persons DELETED outbox rows = $PURGE_OUTBOX (want 1)"

####################################
sec "2. Two role-owned child collections — CRUD, FLAT render, child filters"
####################################
D2="30000000002"
BODY_FULL="{\"name\":\"Alice Pereira\",\"email\":\"alice.emp@example.com\",\"phone\":\"14155552671\",\"document\":\"$D2\",\"employeeNumber\":\"EMP-0002\",
  \"bank\":\"260\",\"branch\":\"0001\",\"account\":\"1234567-8\",\"pix\":\"alice.emp@example.com\",
  \"addresses\":[{\"street\":\"1 Infinite Loop\",\"number\":\"1\",\"neighborhood\":\"Mariani\",\"city\":\"Cupertino\",\"state\":\"CA\",\"zipCode\":\"95014\",\"country\":\"US\"}],
  \"dependents\":[
    {\"name\":\"Maria Silva\",\"birthDate\":\"2015-03-10T00:00:00Z\",\"relationship\":\"daughter\",\"healthPlanProvider\":\"Unimed\",\"healthPlanCard\":\"UN-889923\",\"healthPlanExpiry\":\"2027-12-31T00:00:00Z\"},
    {\"name\":\"Pedro Silva\",\"birthDate\":\"2018-07-22T00:00:00Z\",\"relationship\":\"son\"}
  ],
  \"jobHistories\":[
    {\"jobTitle\":\"Engineer\",\"department\":\"Platform\",\"hiredAt\":\"2022-01-10T00:00:00Z\"},
    {\"jobTitle\":\"Analyst\",\"department\":\"Data\",\"hiredAt\":\"2019-05-01T00:00:00Z\",\"terminatedAt\":\"2021-12-31T00:00:00Z\"}
  ]}"

title "2.1 POST full employee (2 dependents, one WITH plan; 2 job histories)"
req POST /employees "$BODY_FULL"
expect_status "create full employee" 201
EID2=$(jsonq "d['data']['id']")

title "2.2 Normalization: one row per table, conditional child sibling"
for check in "employees|1" "employee_bank_accounts|1" "employee_dependents|2" "dependent_health_plans|1" "employee_job_histories|2"; do
  tbl="${check%%|*}"; want="${check##*|}"
  got=$(qa_db_query "SELECT count(*) FROM $tbl;")
  [ "$got" = "$want" ] && ok "$tbl rows = $want" || bad "$tbl rows = $got (want $want)"
done

title "2.3 View doc renders children FLAT (dependents with plan fields inline)"
wait_view_total "document=$D2" 1 || bad "employee doc never reached the view"
req GET "/employees?document=$D2"
DEPS=$(jsonq "len(d['data'][0]['dependents'])")
HISTS=$(jsonq "len(d['data'][0]['jobHistories'])")
PLAN=$(jsonq "[x.get('healthPlanProvider') for x in d['data'][0]['dependents'] if x['name']=='Maria Silva'][0]")
NOPLAN=$(jsonq "[x.get('healthPlanProvider') for x in d['data'][0]['dependents'] if x['name']=='Pedro Silva'][0]")
BANK=$(jsonq "d['data'][0]['bank']")
[ "$DEPS" = "2" ] && ok "dependents[] materialized (2)" || bad "dependents=$DEPS"
[ "$HISTS" = "2" ] && ok "jobHistories[] materialized (2)" || bad "jobHistories=$HISTS"
[ "$PLAN" = "Unimed" ] && ok "child-sibling fields merged FLAT into the dependent" || bad "plan provider=$PLAN"
[ "$NOPLAN" = "None" ] && ok "plan-less dependent renders nil plan fields" || bad "unexpected plan on Pedro: $NOPLAN"
[ "$BANK" = "260" ] && ok "role-sibling fields merged FLAT into the root" || bad "bank=$BANK"

title "2.4 Filters by child path, child-SIBLING path, and root sibling field"
req GET "/employees?dependents.relationship=daughter&onlyTotal=true"
[ "$(jsonq "d['pagination']['total']")" = "1" ] && ok "?dependents.relationship=daughter → 1" || bad "child filter failed: $RESP"
req GET "/employees?dependents.healthPlanProvider=Unimed&onlyTotal=true"
[ "$(jsonq "d['pagination']['total']")" = "1" ] && ok "?dependents.healthPlanProvider=Unimed (child-sibling leaf) → 1" || bad "child-sibling filter failed: $RESP"
req GET "/employees?jobHistories.department=Data&onlyTotal=true"
[ "$(jsonq "d['pagination']['total']")" = "1" ] && ok "?jobHistories.department=Data → 1" || bad "second-child filter failed: $RESP"
req GET "/employees?dependents.relationship=mother&onlyTotal=true"
[ "$(jsonq "d['pagination']['total']")" = "0" ] && ok "negative child filter → 0" || bad "negative filter: $RESP"
req GET "/employees?bank=260&onlyTotal=true"
[ "$(jsonq "d['pagination']['total']")" = "1" ] && ok "?bank=260 (root sibling field) → 1" || bad "sibling filter failed: $RESP"

title "2.5 Sort by child field is accepted"
req GET "/employees?sort=dependents.name&fields=name"
expect_status "GET ?sort=dependents.name" 200

title "2.6 Unknown child key stays rejected by the allowlist"
req GET "/employees?dependents.unknown=x"
expect_status "unknown nested filter key → 400" 400

####################################
sec "3. A2b — sibling of a CHILD (dependent_health_plans) PUT/PATCH semantics"
####################################
title "3.1 PUT filling Pedro's plan → the child-sibling row materializes"
BODY_PUT1="{\"name\":\"Alice Pereira\",\"email\":\"alice.emp@example.com\",\"phone\":\"14155552671\",\"employeeNumber\":\"EMP-0002\",
  \"bank\":\"260\",\"branch\":\"0001\",\"account\":\"1234567-8\",\"pix\":\"alice.emp@example.com\",
  \"addresses\":[{\"street\":\"1 Infinite Loop\",\"number\":\"1\",\"neighborhood\":\"Mariani\",\"city\":\"Cupertino\",\"state\":\"CA\",\"zipCode\":\"95014\",\"country\":\"US\"}],
  \"dependents\":[
    {\"name\":\"Maria Silva\",\"birthDate\":\"2015-03-10T00:00:00Z\",\"relationship\":\"daughter\",\"healthPlanProvider\":\"Unimed\",\"healthPlanCard\":\"UN-889923\",\"healthPlanExpiry\":\"2027-12-31T00:00:00Z\"},
    {\"name\":\"Pedro Silva\",\"birthDate\":\"2018-07-22T00:00:00Z\",\"relationship\":\"son\",\"healthPlanProvider\":\"Amil\",\"healthPlanCard\":\"AM-11\",\"healthPlanExpiry\":\"2026-12-31T00:00:00Z\"}
  ],
  \"jobHistories\":[{\"jobTitle\":\"Engineer\",\"department\":\"Platform\",\"hiredAt\":\"2022-01-10T00:00:00Z\"}]}"
req PUT "/employees/$EID2" "$BODY_PUT1"
expect_status "PUT with Pedro's plan filled" 200
PEDRO_PLAN=$(qa_db_query "SELECT count(*) FROM dependent_health_plans hp JOIN employee_dependents d ON hp.id = d.id WHERE d.name = 'Pedro Silva' AND d.deleted_at IS NULL;")
[ "$PEDRO_PLAN" = "1" ] && ok "PUT created the plan row for the ACTIVE Pedro" || bad "active Pedro plan rows = $PEDRO_PLAN"

title "3.2 Root PATCH does NOT touch children or their siblings"
BEFORE_DEP=$(qa_db_query "SELECT count(*) FROM employee_dependents WHERE deleted_at IS NULL;")
BEFORE_PLAN=$(qa_db_query "SELECT count(*) FROM dependent_health_plans;")
req PATCH "/employees/$EID2" '{"name":"Alice P. Patched"}'
expect_status "PATCH root name" 200
AFTER_DEP=$(qa_db_query "SELECT count(*) FROM employee_dependents WHERE deleted_at IS NULL;")
AFTER_PLAN=$(qa_db_query "SELECT count(*) FROM dependent_health_plans;")
if [ "$BEFORE_DEP" = "$AFTER_DEP" ] && [ "$BEFORE_PLAN" = "$AFTER_PLAN" ]; then
  ok "PATCH left dependents ($AFTER_DEP) and plan rows ($AFTER_PLAN) untouched"
else
  bad "PATCH disturbed children: deps $BEFORE_DEP→$AFTER_DEP plans $BEFORE_PLAN→$AFTER_PLAN"
fi

title "3.3 PUT clearing Pedro's plan → the child-sibling row is removed"
BODY_PUT2="{\"name\":\"Alice P. Patched\",\"email\":\"alice.emp@example.com\",\"phone\":\"14155552671\",\"employeeNumber\":\"EMP-0002\",
  \"bank\":\"260\",\"branch\":\"0001\",\"account\":\"1234567-8\",\"pix\":\"alice.emp@example.com\",
  \"addresses\":[{\"street\":\"1 Infinite Loop\",\"number\":\"1\",\"neighborhood\":\"Mariani\",\"city\":\"Cupertino\",\"state\":\"CA\",\"zipCode\":\"95014\",\"country\":\"US\"}],
  \"dependents\":[
    {\"name\":\"Maria Silva\",\"birthDate\":\"2015-03-10T00:00:00Z\",\"relationship\":\"daughter\",\"healthPlanProvider\":\"Unimed\",\"healthPlanCard\":\"UN-889923\",\"healthPlanExpiry\":\"2027-12-31T00:00:00Z\"},
    {\"name\":\"Pedro Silva\",\"birthDate\":\"2018-07-22T00:00:00Z\",\"relationship\":\"son\"}
  ],
  \"jobHistories\":[{\"jobTitle\":\"Engineer\",\"department\":\"Platform\",\"hiredAt\":\"2022-01-10T00:00:00Z\"}]}"
req PUT "/employees/$EID2" "$BODY_PUT2"
expect_status "PUT with Pedro's plan cleared" 200
PEDRO_PLAN=$(qa_db_query "SELECT count(*) FROM dependent_health_plans hp JOIN employee_dependents d ON hp.id = d.id WHERE d.name = 'Pedro Silva' AND d.deleted_at IS NULL;")
[ "$PEDRO_PLAN" = "0" ] && ok "PUT removed the plan row from the ACTIVE Pedro" || bad "active Pedro plan rows = $PEDRO_PLAN (want 0)"
MARIA_PLAN=$(qa_db_query "SELECT count(*) FROM dependent_health_plans hp JOIN employee_dependents d ON hp.id = d.id WHERE d.name = 'Maria Silva' AND d.deleted_at IS NULL;")
[ "$MARIA_PLAN" = "1" ] && ok "Maria's plan row untouched" || bad "Maria plan rows = $MARIA_PLAN"

####################################
sec "4. Role sibling (employee_bank_accounts) — conditional materialization"
####################################
D4="30000000004"
title "4.1 POST without any bank field → no sibling row"
req POST /employees "{\"name\":\"No Bank\",\"email\":\"nobank@example.com\",\"document\":\"$D4\",\"employeeNumber\":\"EMP-0004\"}"
expect_status "create bankless employee" 201
EID4=$(jsonq "d['data']['id']")
CNT=$(qa_db_query "SELECT count(*) FROM employee_bank_accounts WHERE id = $(qa_uuid_lit "$EID4");")
[ "$CNT" = "0" ] && ok "all-nil facet skipped on INSERT" || bad "bank rows = $CNT (want 0)"

title "4.2 PATCH sending one bank field → sibling row upserts"
req PATCH "/employees/$EID4" '{"bank":"341"}'
expect_status "PATCH bank" 200
CNT=$(qa_db_query "SELECT count(*) FROM employee_bank_accounts WHERE id = $(qa_uuid_lit "$EID4");")
[ "$CNT" = "1" ] && ok "PATCH materialized the sibling row" || bad "bank rows = $CNT (want 1)"

title "4.3 PATCH touching an unrelated field → sibling untouched"
req PATCH "/employees/$EID4" '{"name":"No Bank Renamed"}'
expect_status "PATCH name only" 200
VAL=$(qa_db_query "SELECT bank FROM employee_bank_accounts WHERE id = $(qa_uuid_lit "$EID4");")
[ "$VAL" = "341" ] && ok "sibling value preserved through unrelated PATCH" || bad "bank value = '$VAL'"

title "4.4 PUT omitting the whole facet → sibling row removed"
req PUT "/employees/$EID4" "{\"name\":\"No Bank Renamed\",\"email\":\"nobank@example.com\",\"phone\":null,\"employeeNumber\":\"EMP-0004\",\"bank\":null,\"branch\":null,\"account\":null,\"pix\":null,\"addresses\":[],\"dependents\":[],\"jobHistories\":[]}"
expect_status "PUT without bank facet" 200
CNT=$(qa_db_query "SELECT count(*) FROM employee_bank_accounts WHERE id = $(qa_uuid_lit "$EID4");")
[ "$CNT" = "0" ] && ok "PUT removed the sibling row (absent facet = remove)" || bad "bank rows = $CNT (want 0)"

####################################
sec "5. Archive/unarchive — cascade over role children, base keep-by-default"
####################################
D5="30000000005"
title "5.1 Fixture: person with BOTH roles + employee children"
req POST /users "{\"name\":\"Two Roles\",\"email\":\"tworoles@example.com\",\"document\":\"$D5\",\"userName\":\"tworoles\"}"
expect_status "create user role" 201
req POST /employees "{\"name\":\"Two Roles\",\"email\":\"tworoles@example.com\",\"document\":\"$D5\",\"employeeNumber\":\"EMP-0005\",
  \"dependents\":[{\"name\":\"Kid A\",\"birthDate\":\"2019-01-01T00:00:00Z\",\"relationship\":\"son\"}],
  \"jobHistories\":[{\"jobTitle\":\"Clerk\",\"department\":\"Ops\",\"hiredAt\":\"2023-02-01T00:00:00Z\"}]}"
expect_status "create employee role" 201
EID5=$(jsonq "d['data']['id']")

title "5.2 Archive the employee → role + ITS children archive; person stays ACTIVE (user role alive)"
req PATCH "/employees/$EID5/archive"
expect_status "archive employee" 204
EDEL=$(qa_db_query "SELECT count(*) FROM employees WHERE id = $(qa_uuid_lit "$EID5") AND deleted_at IS NOT NULL;")
DDEL=$(qa_db_query "SELECT count(*) FROM employee_dependents WHERE employee_id = $(qa_uuid_lit "$EID5") AND deleted_at IS NOT NULL;")
HDEL=$(qa_db_query "SELECT count(*) FROM employee_job_histories WHERE employee_id = $(qa_uuid_lit "$EID5") AND deleted_at IS NOT NULL;")
PACT=$(qa_db_query "SELECT count(*) FROM persons WHERE id = $(qa_uuid_lit "$EID5") AND deleted_at IS NULL;")
[ "$EDEL" = "1" ] && ok "employee row archived" || bad "employee archived rows = $EDEL"
[ "$DDEL" = "1" ] && ok "dependent archived in cascade" || bad "dependent archived rows = $DDEL"
[ "$HDEL" = "1" ] && ok "job history archived in cascade" || bad "job history archived rows = $HDEL"
[ "$PACT" = "1" ] && ok "person stays ACTIVE while the user role is active (keep-by-default across roles)" || bad "person active rows = $PACT"

title "5.3 Read-side: archived employee hidden by default, visible with includeArchived"
# Gate on the RIGHT predicate: the ARCHIVED doc materialized (visible via
# includeArchived). The default-read total is 0 BEFORE the doc lands too, so
# waiting on it is vacuous — it cannot tell "hidden because archived" from
# "not projected yet" (the race the Oracle lane's ~2-3s LogMiner floor loses;
# the other relays answer in sub-second and never exposed it). The asserts
# below stay untouched — this only honors the documented eventual consistency.
wait_view_total "document=$D5&includeArchived=true" 1 || true
req GET "/employees?document=$D5&onlyTotal=true"
[ "$(jsonq "d['pagination']['total']")" = "0" ] && ok "default read hides archived" || bad "archived doc still listed: $RESP"
req GET "/employees?document=$D5&includeArchived=true&onlyTotal=true"
[ "$(jsonq "d['pagination']['total']")" = "1" ] && ok "?includeArchived=true surfaces it" || bad "includeArchived read: $RESP"

title "5.4 Archive the USER too → the LAST active role goes, the base converges to archived"
# CDC poll before extracting the id (the e2e suite's own by-id pattern): the
# user doc is eventually consistent, and a bare GET can run ahead of the
# projection on a slower relay.
for _ in $(seq 1 67); do
  req GET "/users/$EID5"
  [ "$STATUS" = "200" ] && break
  sleep 0.3
done
UARCH=$(jsonq "d['data']['id']")
req PATCH "/users/$UARCH/archive"
expect_status "archive user (last active role)" 204
PARCH=$(qa_db_query "SELECT count(*) FROM persons WHERE id = $(qa_uuid_lit "$EID5") AND deleted_at IS NOT NULL;")
[ "$PARCH" = "1" ] && ok "base archived once the last active role went" || bad "person archived rows = $PARCH"

title "5.5 Unarchive the employee → role + children restore; base revives with its first active role"
req PATCH "/employees/$EID5/unarchive"
expect_status "unarchive employee" 204
EACT=$(qa_db_query "SELECT count(*) FROM employees WHERE id = $(qa_uuid_lit "$EID5") AND deleted_at IS NULL;")
DACT=$(qa_db_query "SELECT count(*) FROM employee_dependents WHERE employee_id = $(qa_uuid_lit "$EID5") AND deleted_at IS NULL;")
PACT=$(qa_db_query "SELECT count(*) FROM persons WHERE id = $(qa_uuid_lit "$EID5") AND deleted_at IS NULL;")
[ "$EACT" = "1" ] && ok "employee restored" || bad "employee active rows = $EACT"
[ "$DACT" = "1" ] && ok "dependent restored in cascade" || bad "dependent active rows = $DACT"
[ "$PACT" = "1" ] && ok "base revived with its first active role" || bad "person active rows = $PACT"

####################################
sec "6. CSV + XLSX hierarchical export — child + sibling columns"
####################################
title "6.1 CSV carries root+sibling headers and both child blocks"
CSV=$(curl -sS -H "Accept-Language: en-US" "$BASE/employees.csv?document=$D2")
echo "$CSV" | head -8
for hdr in "Employee number" "Bank" "Dependent name" "Health plan provider" "Job title" "Hire date"; do
  echo "$CSV" | grep -q "$hdr" && ok "CSV header '$hdr' present" || bad "CSV header '$hdr' missing"
done
echo "$CSV" | grep -q "Maria Silva" && ok "CSV dependent row present" || bad "CSV dependent row missing"
echo "$CSV" | grep -q "Engineer" && ok "CSV job-history row present" || bad "CSV job-history row missing"

title "6.2 XLSX responds with a workbook"
XLSX_STATUS=$(curl -sS -o /tmp/qa_employee.xlsx.${BACKEND:-default} -w "%{http_code}" "$BASE/employees.xlsx?document=$D2")
SIG=$(head -c 2 /tmp/qa_employee.xlsx.${BACKEND:-default})
[ "$XLSX_STATUS" = "200" ] && [ "$SIG" = "PK" ] && ok "XLSX 200 + ZIP signature" || bad "XLSX status=$XLSX_STATUS sig=$SIG"
rm -f /tmp/qa_employee.xlsx.${BACKEND:-default}

####################################
sec "7. GraphQL — same handlers, full mutation set"
####################################
gql() { # gql <query-json>
  local tmp; tmp=$(mktemp)
  STATUS=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST "$BASE/graphql" \
    -H "Content-Type: application/json" --data "$1")
  RESP=$(cat "$tmp"); rm -f "$tmp"
}

title "7.1 Connection query with where-filter + totalCount + nested children"
gql "{\"query\":\"{ employees(where: {document: {eq: \\\"$D2\\\"}}) { totalCount edges { node { name employeeNumber bank dependents { name relationship healthPlanProvider } jobHistories { jobTitle department } } } } }\"}"
TOTAL=$(jsonq "d['data']['employees']['totalCount']")
DEPN=$(jsonq "len(d['data']['employees']['edges'][0]['node']['dependents'])")
[ "$TOTAL" = "1" ] && ok "GraphQL where-filter totalCount=1" || bad "GraphQL totalCount=$TOTAL — $RESP"
[ "$DEPN" = "2" ] && ok "GraphQL renders nested dependents" || bad "GraphQL dependents=$DEPN"

title "7.2 count-only (totalCount without edges)"
gql "{\"query\":\"{ employees(where: {dependents_relationship: {eq: \\\"daughter\\\"}}) { totalCount } }\"}"
[ "$(jsonq "d['data']['employees']['totalCount']")" = "1" ] && ok "GraphQL child filter count" || bad "GraphQL child filter: $RESP"

title "7.3 createEmployee mutation"
D7="30000000007"
gql "{\"query\":\"mutation { createEmployee(input: {name: \\\"Gql Emp\\\", email: \\\"gql@example.com\\\", document: \\\"$D7\\\", employeeNumber: \\\"EMP-0007\\\", dependents: [{name: \\\"Gql Kid\\\", birthDate: \\\"2020-05-05T00:00:00Z\\\", relationship: \\\"daughter\\\"}], jobHistories: [{jobTitle: \\\"Intern\\\", department: \\\"Lab\\\", hiredAt: \\\"2024-01-02T00:00:00Z\\\"}]}) { id employeeNumber } }\"}"
GQL_ID=$(jsonq "d['data']['createEmployee']['id']")
[ -n "$GQL_ID" ] && [ "$GQL_ID" != "None" ] && ok "createEmployee returned id $GQL_ID" || bad "createEmployee failed: $RESP"

title "7.4 updateEmployee (PUT semantics) + patchEmployee"
gql "{\"query\":\"mutation { updateEmployee(id: \\\"$GQL_ID\\\", input: {name: \\\"Gql Emp Updated\\\", email: \\\"gql@example.com\\\", phone: \\\"14155550000\\\", employeeNumber: \\\"EMP-0007\\\", bank: \\\"777\\\", branch: \\\"0001\\\", account: \\\"9\\\", pix: \\\"g@x.io\\\", addresses: [], dependents: [], jobHistories: []}) { name bank } }\"}"
[ "$(jsonq "d['data']['updateEmployee']['name']")" = "Gql Emp Updated" ] && ok "updateEmployee applied" || bad "updateEmployee: $RESP"
gql "{\"query\":\"mutation { patchEmployee(id: \\\"$GQL_ID\\\", input: {employeeNumber: \\\"EMP-0007B\\\"}) { employeeNumber } }\"}"
[ "$(jsonq "d['data']['patchEmployee']['employeeNumber']")" = "EMP-0007B" ] && ok "patchEmployee applied" || bad "patchEmployee: $RESP"

title "7.5 archive/unarchive/delete mutations"
gql "{\"query\":\"mutation { archiveEmployee(id: \\\"$GQL_ID\\\") { success } }\"}"
[ "$(jsonq "d['data']['archiveEmployee']['success']")" = "True" ] && ok "archiveEmployee" || bad "archiveEmployee: $RESP"
gql "{\"query\":\"mutation { unarchiveEmployee(id: \\\"$GQL_ID\\\") { success } }\"}"
[ "$(jsonq "d['data']['unarchiveEmployee']['success']")" = "True" ] && ok "unarchiveEmployee" || bad "unarchiveEmployee: $RESP"
gql "{\"query\":\"mutation { deleteEmployee(id: \\\"$GQL_ID\\\") { success } }\"}"
[ "$(jsonq "d['data']['deleteEmployee']['success']")" = "True" ] && ok "deleteEmployee" || bad "deleteEmployee: $RESP"

title "7.6 GraphQL validation error mirrors REST (422 envelope in errors)"
gql "{\"query\":\"mutation { createEmployee(input: {name: \\\"X\\\", email: \\\"bad@example.com\\\", document: \\\"30000000008\\\", employeeNumber: \\\"EMP-8\\\", dependents: [{name: \\\"K\\\", birthDate: \\\"2020-01-01T00:00:00Z\\\", relationship: \\\"cousin\\\"}], jobHistories: []}) { id } }\"}"
ERRS=$(jsonq "len(d.get('errors') or [])")
[ "$ERRS" != "0" ] && [ "$ERRS" != "None" ] && ok "invalid relationship rejected through GraphQL" || bad "expected GraphQL errors: $RESP"

####################################
sec "8. REST validation — domain rules on children"
####################################
title "8.1 Relationship outside the closed set → 422"
req POST /employees "{\"name\":\"Bad Rel\",\"email\":\"badrel@example.com\",\"document\":\"30000000009\",\"employeeNumber\":\"EMP-9\",\"dependents\":[{\"name\":\"K\",\"birthDate\":\"2020-01-01T00:00:00Z\",\"relationship\":\"cousin\"}]}"
expect_status "invalid relationship" 422
echo "$RESP" | grep -q "InvalidRelationshipNotification" && ok "InvalidRelationshipNotification on the wire" || bad "notification missing: $RESP"

title "8.2 Termination before hire → 422"
req POST /employees "{\"name\":\"Bad Hist\",\"email\":\"badhist@example.com\",\"document\":\"30000000010\",\"employeeNumber\":\"EMP-10\",\"jobHistories\":[{\"jobTitle\":\"X\",\"department\":\"Y\",\"hiredAt\":\"2024-01-01T00:00:00Z\",\"terminatedAt\":\"2023-01-01T00:00:00Z\"}]}"
expect_status "termination before hire" 422
echo "$RESP" | grep -q "TerminationBeforeHireNotification" && ok "TerminationBeforeHireNotification on the wire" || bad "notification missing: $RESP"

title "8.3 Duplicate ACTIVE employee for the same document → 409"
req POST /employees "{\"name\":\"Alice P. Patched\",\"email\":\"alice.emp@example.com\",\"document\":\"$D2\",\"employeeNumber\":\"EMP-0002\"}"
expect_status "duplicate active employee" 409

title "8.4 Missing employeeNumber → 422 (role-private required field)"
req POST /employees "{\"name\":\"No Num\",\"email\":\"nonum@example.com\",\"document\":\"30000000011\"}"
expect_status "missing employeeNumber" 422


####################################
# Cross-role matrix — sections 9-12 exercise every combination two roles of
# ONE person can produce. View-level assertions on children/name count ACTIVE
# entries, isolating the cross-role PROPAGATION dimension. The two read-side
# findings these once tripped are now fixed and locked green: A5 (the base's
# deleted_at must not clobber the role's own) in sections 5.3-5.4, and A4
# (archived aggregate children must not leak into the composed doc) end-to-end
# in section 13.
####################################

# memp <js> — evaluate js against this backend's Mongo view DB.
memp() { docker exec omnicore-qa-mongo mongosh "$QA_MONGO_DB" --quiet --eval "$1"; }

# wait_memp <js> <expected> [timeout] — poll a Mongo eval until it matches.
wait_memp() {
  local js="$1" expected="$2" timeout="${3:-20}"
  local deadline=$(( $(date +%s) + timeout )) got
  while [ "$(date +%s)" -lt "$deadline" ]; do
    got=$(memp "$js")
    [ "$got" = "$expected" ] && return 0
    sleep 0.3
  done
  echo "(last value: $got)"
  return 1
}

####################################
sec "9. Cross-role shared fields — last-write-wins + fan-out in BOTH directions"
####################################
D9="30000000021"

title "9.1 POST /users doc $D9 with name 'Cross XXX'"
req POST /users "{\"name\":\"Cross XXX\",\"email\":\"cross9@example.com\",\"document\":\"$D9\",\"userName\":\"cross9\"}"
expect_status "create user (name XXX)" 201
ID9=$(jsonq "d['data']['id']")
wait_memp "var d=db.users.findOne({document:'$D9'}); print(d ? d.name : 'absent')" "Cross XXX" \
  && ok "user view materialized with 'Cross XXX'" || bad "user view never showed XXX"

title "9.2 POST /employees SAME doc with name 'Cross YYY' → last-write-wins on the base"
req POST /employees "{\"name\":\"Cross YYY\",\"email\":\"cross9@example.com\",\"document\":\"$D9\",\"employeeNumber\":\"EMP-C9\"}"
expect_status "create employee (name YYY)" 201
PNAME=$(qa_db_query "SELECT name FROM persons WHERE document='$D9';")
[ "$PNAME" = "Cross YYY" ] && ok "persons.name = 'Cross YYY' (last write wins)" || bad "persons.name = '$PNAME'"

title "9.3 BOTH views converge to the employee's write (fan-out on role INSERT)"
wait_memp "var d=db.employees.findOne({document:'$D9'}); print(d ? d.name : 'absent')" "Cross YYY" \
  && ok "employee view shows 'Cross YYY'" || bad "employee view stale"
wait_memp "var d=db.users.findOne({document:'$D9'}); print(d ? d.name : 'absent')" "Cross YYY" \
  && ok "USER view recomposed to 'Cross YYY' after the EMPLOYEE insert" || bad "user view stale after employee insert"

title "9.4 PATCH the USER's name → both views converge (fan-out user→employee)"
AUD_EMP_BEFORE=$(qa_db_query "SELECT count(*) FROM audit_events WHERE entity_type='Employee';")
OUTBOX_P_BEFORE=$(qa_db_query "SELECT count(*) FROM outbox WHERE aggregate_type='persons' AND event_type='UPDATED';")
req PATCH "/users/$ID9" '{"name":"Cross ZZZ"}'
expect_status "PATCH user name" 200
PNAME=$(qa_db_query "SELECT name FROM persons WHERE document='$D9';")
[ "$PNAME" = "Cross ZZZ" ] && ok "persons.name = 'Cross ZZZ'" || bad "persons.name = '$PNAME'"
wait_memp "var d=db.users.findOne({document:'$D9'}); print(d ? d.name : 'absent')" "Cross ZZZ" \
  && ok "user view shows 'Cross ZZZ'" || bad "user view stale"
wait_memp "var d=db.employees.findOne({document:'$D9'}); print(d ? d.name : 'absent')" "Cross ZZZ" \
  && ok "EMPLOYEE view recomposed to 'Cross ZZZ' after the USER patch" || bad "employee view stale after user patch"

title "9.5 Audit isolation: the USER patch produced NO Employee audit event, and one persons UPDATED outbox row"
AUD_EMP_AFTER=$(qa_db_query "SELECT count(*) FROM audit_events WHERE entity_type='Employee';")
OUTBOX_P_AFTER=$(qa_db_query "SELECT count(*) FROM outbox WHERE aggregate_type='persons' AND event_type='UPDATED';")
[ "$AUD_EMP_BEFORE" = "$AUD_EMP_AFTER" ] && ok "no Employee audit row from a /users operation" \
  || bad "Employee audit rows grew on a /users op: $AUD_EMP_BEFORE -> $AUD_EMP_AFTER"
[ "$OUTBOX_P_AFTER" = "$((OUTBOX_P_BEFORE + 1))" ] && ok "exactly one persons UPDATED outbox row for the shared change" \
  || bad "persons UPDATED outbox: $OUTBOX_P_BEFORE -> $OUTBOX_P_AFTER (want +1)"
# audit_events.aggregate_id is CHAR(36) canonical text on BOTH dialects (the
# audit control table is text-keyed, unlike the BINARY(16) domain tables), so
# the literal is plain quoted text — not qa_uuid_lit.
AUD_USER_UPD=$(qa_db_query "SELECT count(*) FROM audit_events WHERE entity_type='User' AND verb='update' AND aggregate_id='$ID9';")
[ "$AUD_USER_UPD" = "1" ] && ok "User update audit event present (kind delta on the role's own trail)" \
  || bad "User update audit rows = $AUD_USER_UPD (want 1)"

####################################
sec "10. Base children (addresses) edited through EITHER role reflect in BOTH views"
####################################
ADDR1='{"street":"1 Infinite Loop","number":"1","neighborhood":"Mariani","city":"Cupertino","state":"CA","zipCode":"95014","country":"US"}'
ADDR2='{"street":"500 Cross St","number":"9","neighborhood":"Centro","city":"Recife","state":"PE","zipCode":"50000-000","country":"BR"}'

title "10.1 PUT /users adds a SECOND address → employee view gains it"
req PUT "/users/$ID9" "{\"name\":\"Cross ZZZ\",\"email\":\"cross9@example.com\",\"phone\":null,\"userName\":\"cross9\",\"emailNotification\":null,\"smsNotification\":null,\"addresses\":[$ADDR1,$ADDR2]}"
expect_status "PUT user with 2 addresses" 200
ACT=$(qa_db_query "SELECT count(*) FROM addresses a JOIN persons p ON a.person_id=p.id WHERE p.document='$D9' AND a.deleted_at IS NULL;")
[ "$ACT" = "2" ] && ok "2 ACTIVE address rows on the base" || bad "active addresses = $ACT (want 2)"
wait_memp "var d=db.employees.findOne({document:'$D9'}); print(d ? (d.Addresses||[]).filter(x=>!x.deleted_at).length : 'absent')" "2" \
  && ok "EMPLOYEE view carries both active addresses (child added via the USER)" \
  || bad "employee view did not gain the address added through the user"

title "10.2 PUT /employees removes one address → user view loses it"
req PUT "/employees/$ID9" "{\"name\":\"Cross ZZZ\",\"email\":\"cross9@example.com\",\"phone\":null,\"employeeNumber\":\"EMP-C9\",\"bank\":null,\"branch\":null,\"account\":null,\"pix\":null,\"addresses\":[$ADDR1],\"dependents\":[],\"jobHistories\":[]}"
expect_status "PUT employee keeping only the first address" 200
ACT=$(qa_db_query "SELECT count(*) FROM addresses a JOIN persons p ON a.person_id=p.id WHERE p.document='$D9' AND a.deleted_at IS NULL;")
[ "$ACT" = "1" ] && ok "1 ACTIVE address row after the employee's replace" || bad "active addresses = $ACT (want 1)"
wait_memp "var d=db.users.findOne({document:'$D9'}); print(d ? (d.Addresses||[]).filter(x=>!x.deleted_at).length : 'absent')" "1" \
  && ok "USER view dropped the address removed through the EMPLOYEE" \
  || bad "user view did not reflect the removal made through the employee"

title "10.3 Warm upsert dedups a re-sent identical address (cross-role)"
D10="30000000022"
req POST /users "{\"name\":\"Dedup Person\",\"email\":\"dedup@example.com\",\"document\":\"$D10\",\"userName\":\"dedup10\",\"addresses\":[$ADDR1]}"
expect_status "create user with address A1" 201
req POST /employees "{\"name\":\"Dedup Person\",\"email\":\"dedup@example.com\",\"document\":\"$D10\",\"employeeNumber\":\"EMP-C10\",\"addresses\":[$ADDR1]}"
expect_status "create employee re-sending the SAME address" 201
ACT=$(qa_db_query "SELECT count(*) FROM addresses a JOIN persons p ON a.person_id=p.id WHERE p.document='$D10' AND a.deleted_at IS NULL;")
[ "$ACT" = "1" ] && ok "identical address deduped against the base's existing children" \
  || bad "active addresses = $ACT (want 1 — dedup failed)"

####################################
sec "11. Cross soft-delete matrix — reverse order, base convergence, no POST revival"
####################################
D11="30000000023"
req POST /users "{\"name\":\"Soft Cross\",\"email\":\"soft11@example.com\",\"document\":\"$D11\",\"userName\":\"soft11\"}"
expect_status "fixture: user role" 201
ID11=$(jsonq "d['data']['id']")
req POST /employees "{\"name\":\"Soft Cross\",\"email\":\"soft11@example.com\",\"document\":\"$D11\",\"employeeNumber\":\"EMP-C11\",\"dependents\":[{\"name\":\"Soft Kid\",\"birthDate\":\"2019-01-01T00:00:00Z\",\"relationship\":\"son\"}]}"
expect_status "fixture: employee role (with a dependent)" 201

title "11.1 Archive the USER first → base and employee stay ACTIVE (reverse of 5.x)"
req PATCH "/users/$ID11/archive"
expect_status "archive user" 204
ROW=$(qa_db_query "SELECT (SELECT count(*) FROM users u WHERE u.id=$(qa_uuid_lit "$ID11") AND u.deleted_at IS NOT NULL), (SELECT count(*) FROM persons p WHERE p.id=$(qa_uuid_lit "$ID11") AND p.deleted_at IS NULL), (SELECT count(*) FROM employees e WHERE e.id=$(qa_uuid_lit "$ID11") AND e.deleted_at IS NULL);")
ROW=$(printf %s "$ROW" | tr "\t|" "//")
if [ "$ROW" = "1/1/1" ]; then ok "user archived; person + employee still active"; else bad "state: $ROW (want 1/1/1)"; fi

title "11.2 Archive the EMPLOYEE too (last active role) → base converges to archived, dependent cascades"
req PATCH "/employees/$ID11/archive"
expect_status "archive employee" 204
PARCH=$(qa_db_query "SELECT count(*) FROM persons WHERE id=$(qa_uuid_lit "$ID11") AND deleted_at IS NOT NULL;")
DARCH=$(qa_db_query "SELECT count(*) FROM employee_dependents WHERE employee_id=$(qa_uuid_lit "$ID11") AND deleted_at IS NOT NULL;")
[ "$PARCH" = "1" ] && ok "base archived when its LAST active role went (user-first order)" || bad "persons archived = $PARCH"
[ "$DARCH" = "1" ] && ok "dependent archived in cascade" || bad "dependent archived = $DARCH"

title "11.3 Unarchive the USER → base revives; the EMPLOYEE (and its dependent) stay archived"
req PATCH "/users/$ID11/unarchive"
expect_status "unarchive user" 204
ROW=$(qa_db_query "SELECT (SELECT count(*) FROM persons p WHERE p.id=$(qa_uuid_lit "$ID11") AND p.deleted_at IS NULL), (SELECT count(*) FROM employees e WHERE e.id=$(qa_uuid_lit "$ID11") AND e.deleted_at IS NOT NULL), (SELECT count(*) FROM employee_dependents d WHERE d.employee_id=$(qa_uuid_lit "$ID11") AND d.deleted_at IS NOT NULL);")
ROW=$(printf %s "$ROW" | tr "\t|" "//")
if [ "$ROW" = "1/1/1" ]; then ok "base revived; employee + dependent remain archived (role lifecycles independent)"; else bad "state: $ROW (want 1/1/1)"; fi

title "11.4 Re-POST over the ARCHIVED employee → invisible to the probe; shared-PK remnant vetoes → 409"
req POST /employees "{\"name\":\"Soft Cross\",\"email\":\"soft11@example.com\",\"document\":\"$D11\",\"employeeNumber\":\"EMP-C11\"}"
expect_status "re-POST over an archived employee (soft-delete is delete — no revival)" 409
EARCH=$(qa_db_query "SELECT count(*) FROM employees WHERE id=$(qa_uuid_lit "$ID11") AND deleted_at IS NOT NULL;")
[ "$EARCH" = "1" ] && ok "employee stays archived — the rejected POST applied nothing" || bad "employee archived rows = $EARCH"

title "11.5 The explicit way back: /unarchive restores the role AND its children"
req PATCH "/employees/$ID11/unarchive"
expect_status "unarchive the employee" 204
ROW=$(qa_db_query "SELECT (SELECT count(*) FROM employees WHERE id=$(qa_uuid_lit "$ID11") AND deleted_at IS NULL), (SELECT count(*) FROM employee_dependents WHERE employee_id=$(qa_uuid_lit "$ID11") AND deleted_at IS NULL);")
ROW=$(printf %s "$ROW" | tr "\t|" "//")
if [ "$ROW" = "1/1" ]; then ok "role + dependent restored by the explicit unarchive (the ONLY revival path)"; else bad "state after unarchive: $ROW (want 1/1)"; fi

####################################
sec "12. Cross hard-delete matrix — reverse order + archived-row refcount"
####################################
D12="30000000024"
req POST /users "{\"name\":\"Hard Cross\",\"email\":\"hard12@example.com\",\"document\":\"$D12\",\"userName\":\"hard12\",\"addresses\":[$ADDR1]}"
expect_status "fixture: user role (with address)" 201
ID12=$(jsonq "d['data']['id']")
req POST /employees "{\"name\":\"Hard Cross\",\"email\":\"hard12@example.com\",\"document\":\"$D12\",\"employeeNumber\":\"EMP-C12\",\"bank\":\"260\",\"dependents\":[{\"name\":\"Hard Kid\",\"birthDate\":\"2019-01-01T00:00:00Z\",\"relationship\":\"son\",\"healthPlanProvider\":\"Unimed\"}],\"jobHistories\":[{\"jobTitle\":\"Op\",\"department\":\"Ops\",\"hiredAt\":\"2023-01-01T00:00:00Z\"}]}"
expect_status "fixture: employee role (full graph)" 201

title "12.1 DELETE the EMPLOYEE first → its whole role graph clears; base + addresses + user survive"
req DELETE "/employees/$ID12"
expect_status "delete employee (user still references the person)" 204
ROW=$(qa_db_query "SELECT (SELECT count(*) FROM employees WHERE id=$(qa_uuid_lit "$ID12")), (SELECT count(*) FROM employee_dependents WHERE employee_id=$(qa_uuid_lit "$ID12")), (SELECT count(*) FROM dependent_health_plans hp WHERE NOT EXISTS (SELECT 1 FROM employee_dependents d WHERE d.id=hp.id)), (SELECT count(*) FROM employee_bank_accounts WHERE id=$(qa_uuid_lit "$ID12")), (SELECT count(*) FROM persons WHERE id=$(qa_uuid_lit "$ID12")), (SELECT count(*) FROM addresses a WHERE a.person_id=$(qa_uuid_lit "$ID12"));")
ROW=$(printf %s "$ROW" | tr "\t|" "//")
if [ "$ROW" = "0/0/0/0/1/1" ]; then ok "employee graph physically gone; person + address intact"; else bad "state after employee delete: $ROW (want 0/0/0/0/1/1)"; fi
wait_memp "print(db.employees.countDocuments({document:'$D12'}))" "0" \
  && ok "employee doc dropped from its view" || bad "employee doc still in view"
wait_memp "var d=db.users.findOne({document:'$D12'}); print(d ? d.name : 'absent')" "Hard Cross" \
  && ok "user doc SURVIVES with the shared fields intact" || bad "user doc lost after employee delete"

title "12.2 DELETE the USER (last role) → real purge of person + addresses, audited"
PURGE_BEFORE=$(qa_db_query "SELECT count(*) FROM audit_events WHERE entity_type='persons' AND verb='delete';")
req DELETE "/users/$ID12"
expect_status "delete user (purge)" 204
ROW=$(qa_db_query "SELECT (SELECT count(*) FROM persons WHERE id=$(qa_uuid_lit "$ID12")), (SELECT count(*) FROM addresses WHERE person_id=$(qa_uuid_lit "$ID12"));")
ROW=$(printf %s "$ROW" | tr "\t|" "//")
if [ "$ROW" = "0/0" ]; then ok "person + addresses purged (reverse order works too)"; else bad "post-purge state: $ROW (want 0/0)"; fi
PURGE_AFTER=$(qa_db_query "SELECT count(*) FROM audit_events WHERE entity_type='persons' AND verb='delete';")
[ "$PURGE_AFTER" = "$((PURGE_BEFORE + 1))" ] && ok "purge audited (persons delete +1)" || bad "persons delete audit: $PURGE_BEFORE -> $PURGE_AFTER"
wait_memp "print(db.users.countDocuments({document:'$D12'}))" "0" \
  && ok "user doc dropped after the purge" || bad "user doc still in view"

title "12.3 An ARCHIVED role row still counts as a reference — no purge while it exists"
D13="30000000025"
req POST /users "{\"name\":\"Ref Cross\",\"email\":\"ref13@example.com\",\"document\":\"$D13\",\"userName\":\"ref13\"}"
expect_status "fixture: user role" 201
ID13=$(jsonq "d['data']['id']")
req POST /employees "{\"name\":\"Ref Cross\",\"email\":\"ref13@example.com\",\"document\":\"$D13\",\"employeeNumber\":\"EMP-C13\"}"
expect_status "fixture: employee role" 201
req PATCH "/employees/$ID13/archive"
expect_status "archive the employee" 204
req DELETE "/users/$ID13"
expect_status "delete the user (only ACTIVE role, archived employee row remains)" 204
ROW=$(qa_db_query "SELECT (SELECT count(*) FROM persons WHERE id=$(qa_uuid_lit "$ID13")), (SELECT count(*) FROM employees WHERE id=$(qa_uuid_lit "$ID13") AND deleted_at IS NOT NULL);")
ROW=$(printf %s "$ROW" | tr "\t|" "//")
if [ "$ROW" = "1/1" ]; then ok "person KEPT — the archived employee row still references it (row-based refcount)"; else bad "state: $ROW (want person=1, archived employee=1)"; fi

title "12.4 Unarchive + delete the last row → purge finally fires"
req PATCH "/employees/$ID13/unarchive"
expect_status "unarchive employee" 204
req DELETE "/employees/$ID13"
expect_status "delete employee (now the LAST row)" 204
PCOUNT=$(qa_db_query "SELECT count(*) FROM persons WHERE id=$(qa_uuid_lit "$ID13");")
[ "$PCOUNT" = "0" ] && ok "person purged once the last role row was gone" || bad "person rows = $PCOUNT"

####################################
sec "13. Read-side archived-children strip + export strip + A2b survival (A4 lock-in)"
####################################
# A4 was: archived aggregate children leaked into the composed doc and surfaced
# on EVERY default read (REST, GraphQL, CSV/XLSX). It is fixed; this section is
# the end-to-end lock-in on an ACTIVE root. Churn both collections so half the
# children archive (write-side keeps the rows — "Update with StatusRemoved →
# Archive"), then prove the default read shows ONLY active children while
# ?includeArchived surfaces all — across REST, the child-level (A2b) plan facet,
# and the tabular export. Fresh document, every SQL predicate id-scoped, so the
# churn never disturbs the earlier sections' counts.
DA4="40000000030"

title "13.1 Fixture: employee with 2 dependents (Maria carries an A2b plan) + 1 address"
req POST /employees "{\"name\":\"Strip Root\",\"email\":\"strip@example.com\",\"document\":\"$DA4\",\"employeeNumber\":\"EMP-A4\",
  \"addresses\":[{\"street\":\"S1\",\"number\":\"1\",\"neighborhood\":\"N\",\"city\":\"C\",\"state\":\"CA\",\"zipCode\":\"95014\",\"country\":\"US\"}],
  \"dependents\":[
    {\"name\":\"Maria\",\"birthDate\":\"2015-03-10T00:00:00Z\",\"relationship\":\"daughter\",\"healthPlanProvider\":\"Unimed\",\"healthPlanCard\":\"UN-1\",\"healthPlanExpiry\":\"2027-12-31T00:00:00Z\"},
    {\"name\":\"Pedro\",\"birthDate\":\"2018-07-22T00:00:00Z\",\"relationship\":\"son\"}]}"
expect_status "create strip fixture" 201
EIDA4=$(jsonq "d['data']['id']")
wait_view_total "document=$DA4" 1 || bad "strip fixture never reached the view"

title "13.2 PUT replaces both collections → originals archive, new ones insert"
req PUT "/employees/$EIDA4" "{\"name\":\"Strip Root\",\"email\":\"strip@example.com\",\"phone\":null,\"employeeNumber\":\"EMP-A4\",\"bank\":null,\"branch\":null,\"account\":null,\"pix\":null,
  \"addresses\":[{\"street\":\"S2\",\"number\":\"2\",\"neighborhood\":\"N\",\"city\":\"C\",\"state\":\"CA\",\"zipCode\":\"95015\",\"country\":\"US\"},{\"street\":\"S3\",\"number\":\"3\",\"neighborhood\":\"N\",\"city\":\"C\",\"state\":\"CA\",\"zipCode\":\"95016\",\"country\":\"US\"}],
  \"dependents\":[
    {\"name\":\"Ana\",\"birthDate\":\"2016-01-01T00:00:00Z\",\"relationship\":\"daughter\"},
    {\"name\":\"Bruno\",\"birthDate\":\"2017-01-01T00:00:00Z\",\"relationship\":\"son\"}],
  \"jobHistories\":[]}"
expect_status "PUT replace collections" 200

title "13.3 Write side: originals archived (rows kept), new active; removed Maria KEEPS her A2b plan row"
DACT=$(qa_db_query "SELECT count(*) FROM employee_dependents WHERE employee_id=$(qa_uuid_lit "$EIDA4") AND deleted_at IS NULL;")
DARCH=$(qa_db_query "SELECT count(*) FROM employee_dependents WHERE employee_id=$(qa_uuid_lit "$EIDA4") AND deleted_at IS NOT NULL;")
AACT=$(qa_db_query "SELECT count(*) FROM addresses WHERE person_id=$(qa_uuid_lit "$EIDA4") AND deleted_at IS NULL;")
AARCH=$(qa_db_query "SELECT count(*) FROM addresses WHERE person_id=$(qa_uuid_lit "$EIDA4") AND deleted_at IS NOT NULL;")
[ "$DACT" = "2" ] && ok "2 active dependents" || bad "active dependents = $DACT (want 2)"
[ "$DARCH" = "2" ] && ok "2 archived dependents (rows kept by soft-delete)" || bad "archived dependents = $DARCH (want 2)"
[ "$AACT" = "2" ] && ok "2 active addresses" || bad "active addresses = $AACT (want 2)"
[ "$AARCH" = "1" ] && ok "1 archived address (row kept)" || bad "archived addresses = $AARCH (want 1)"
MPLAN=$(qa_db_query "SELECT count(*) FROM dependent_health_plans hp JOIN employee_dependents d ON hp.id = d.id WHERE d.employee_id=$(qa_uuid_lit "$EIDA4") AND d.name = 'Maria' AND d.deleted_at IS NOT NULL;")
[ "$MPLAN" = "1" ] && ok "removed Maria's A2b plan row survives on her archived child row (soft-delete keeps the 1:1 sibling)" \
                   || bad "archived-Maria plan rows = $MPLAN (want 1)"

title "13.4 Default read shows ONLY active children — archived dependents + address stripped, no A2b leak"
deadline=$(( $(date +%s) + 20 )); conv=fail; names=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  req GET "/employees?document=$DA4"
  names=$(jsonq "sorted(x['name'] for x in d['data'][0]['dependents'])")
  [ "$names" = "['Ana', 'Bruno']" ] && { conv=ok; break; }
  sleep 0.3
done
[ "$conv" = ok ] && ok "default read dependents = [Ana, Bruno] (2 archived stripped)" || bad "default dependents did not converge: $names"
NADDR=$(jsonq "len(d['data'][0]['addresses'])")
[ "$NADDR" = "2" ] && ok "default read addresses = 2 (1 archived stripped)" || bad "default addresses = $NADDR (want 2)"
LEAK=$(jsonq "sum(1 for x in d['data'][0]['dependents'] if x.get('healthPlanProvider'))")
[ "$LEAK" = "0" ] && ok "no A2b plan leaks from archived dependents on the default read" || bad "plan-bearing active deps = $LEAK (want 0)"

title "13.5 ?includeArchived=true surfaces every child — archived dependents + address, with Maria's A2b plan"
req GET "/employees?document=$DA4&includeArchived=true"
INAMES=$(jsonq "sorted(x['name'] for x in d['data'][0]['dependents'])")
[ "$INAMES" = "['Ana', 'Bruno', 'Maria', 'Pedro']" ] && ok "includeArchived dependents = all 4" || bad "includeArchived dependents = $INAMES"
INADDR=$(jsonq "len(d['data'][0]['addresses'])")
[ "$INADDR" = "3" ] && ok "includeArchived addresses = 3 (archived surfaced)" || bad "includeArchived addresses = $INADDR (want 3)"
IMPLAN=$(jsonq "[x.get('healthPlanProvider') for x in d['data'][0]['dependents'] if x['name']=='Maria'][0]")
[ "$IMPLAN" = "Unimed" ] && ok "archived Maria still carries her A2b plan under includeArchived" || bad "archived-Maria plan under includeArchived = $IMPLAN"

title "13.6 Tabular export honors the strip — CSV default excludes archived children"
CSV=$(curl -sS -H "Accept-Language: en-US" "$BASE/employees.csv?document=$DA4")
echo "$CSV" | grep -q ",Ana," && ok "CSV carries active dependent Ana" || bad "CSV missing active Ana"
echo "$CSV" | grep -q ",Bruno," && ok "CSV carries active dependent Bruno" || bad "CSV missing active Bruno"
echo "$CSV" | grep -q ",Maria," && bad "CSV leaked archived dependent Maria" || ok "CSV excludes archived Maria"
echo "$CSV" | grep -q ",Pedro," && bad "CSV leaked archived dependent Pedro" || ok "CSV excludes archived Pedro"

title "13.7 CSV ?includeArchived=true includes the archived children"
CSV=$(curl -sS -H "Accept-Language: en-US" "$BASE/employees.csv?document=$DA4&includeArchived=true")
echo "$CSV" | grep -q ",Maria," && ok "CSV includeArchived surfaces archived Maria" || bad "CSV includeArchived missing Maria"
echo "$CSV" | grep -q ",Pedro," && ok "CSV includeArchived surfaces archived Pedro" || bad "CSV includeArchived missing Pedro"

####################################
sec "Summary"
####################################
hr
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ] || exit 1
