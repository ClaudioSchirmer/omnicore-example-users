#!/usr/bin/env bash
# End-to-end suite for the ALL-IN-ONE person view — the SharedBaseView rooted
# at the shared Person identity (GET /persons, /persons/:id, exports, GraphQL).
# It proves the read-side paths the per-role views cannot:
#
#   1. One document per identity: shared fields flat at the root, the shared
#      addresses at the root, and one sub-object per role — user-only person
#      omits the employee key (explicit null segment + omitempty).
#   2. Two-role composition: adding the Employee role to the same document
#      grows the SAME person doc (dedup by UUIDv5(document)); the bank sibling
#      renders flat inside the segment, dependents/jobHistories nest inside it.
#   3. Cross-role convergence: a shared-field change through EITHER role
#      updates the person root (role event → base-rooted recompose).
#   4. Role-path filters (?user.userName=, ?employee.dependents.relationship=,
#      the child-SIBLING leaf ?employee.dependents.healthPlanProvider=) + the
#      exact-allowlist 400 on an undeclared key.
#   5. Sparse render (?fields=) through a role segment + sort.
#   6. Role lifecycle on the segment: an ARCHIVED role hides on default reads
#      and surfaces (with deletedAt) under ?includeArchived=true, while the
#      person stays visible through its other active role; /unarchive restores.
#   7. Base convergence: archiving the LAST active role hides the person at
#      the ROOT (404 by-id, 0 total) — ?includeArchived surfaces it; reviving
#      one role revives the person.
#   8. Hard-delete of one role: the segment vanishes (even with
#      includeArchived — the row is GONE, resolved via the DELETED payload FK).
#   9. Hard-delete of the last role: the identity purges and the person doc is
#      REMOVED (404 even with includeArchived).
#  10. CSV/XLSX hierarchical export with role branches (no repeated base cols).
#  11. GraphQL persons connection carrying the role sub-objects.
#
# Dialect-driven via qa/_backend.sh (BACKEND=postgres|mysql). Needs the service
# already running on :8080 with APP_PROFILE=dev and the Debezium connector
# registered (same contract as e2e.sh / employee.sh).
#
# Run from anywhere:  bash qa/person.sh
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

expect_status() {
  if [ "$STATUS" = "$2" ]; then ok "$1 (status $STATUS)"; else bad "$1 (expected $2, got $STATUS) — $RESP"; fi
}

jsonq() { printf '%s' "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }

# wait_person <query-string> <python-cond-on-d> [timeout] — polls GET /persons
# until the condition over the parsed response is True (CDC is eventually
# consistent; role events recompose asynchronously).
wait_person() {
  local qs="$1" cond="$2" timeout="${3:-20}"
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    req GET "/persons?$qs"
    if [ "$(jsonq "$cond")" = "True" ]; then return 0; fi
    sleep 0.3
  done
  return 1
}

D1="70000000001"
D2="70000000002"

####################################
sec "0. Health + clean slate + CDC warm-up"
####################################
req GET /livez
expect_status "GET /livez" 200
qa_db_reset_domain
qa_mongo_reset
ok "domain tables + view collections reset"

title "0.1 CDC warm-up probe"
req POST /users '{"name":"Cdc Probe","email":"probe@example.com","document":"70000000000","userName":"cdcprobe"}'
if [ "$STATUS" = "201" ]; then
  if wait_person "document=70000000000&onlyTotal=true" "d['pagination']['total'] == 1" 60; then
    ok "CDC pipeline warm (probe person materialized)"
  else
    bad "CDC pipeline never delivered the probe person in 60s"
  fi
  qa_db_reset_domain; qa_mongo_reset
else
  bad "probe POST failed ($STATUS)"
fi

####################################
sec "1. User-only person: root + addresses + user segment, NO employee key"
####################################
req POST /users "{\"name\":\"Ana Souza\",\"email\":\"ana@example.com\",\"document\":\"$D1\",\"userName\":\"ana\",\"emailNotification\":true,\"addresses\":[{\"street\":\"Rua A\",\"number\":\"1\",\"neighborhood\":\"Centro\",\"city\":\"POA\",\"state\":\"RS\",\"zipCode\":\"90000000\",\"country\":\"BR\"}]}"
expect_status "1.1 POST /users (first role)" 201
USER_ID=$(jsonq "d['data']['id']")

wait_person "document=$D1" "len(d['data']) == 1" && ok "1.2 person doc materialized" || bad "1.2 person doc never materialized"
req GET "/persons?document=$D1"
[ "$(jsonq "d['data'][0]['name']")" = "Ana Souza" ] && ok "1.3 shared fields flat at the root" || bad "1.3 root fields wrong — $RESP"
[ "$(jsonq "len(d['data'][0]['addresses'])")" = "1" ] && ok "1.4 addresses nest at the ROOT" || bad "1.4 addresses missing — $RESP"
[ "$(jsonq "d['data'][0]['user']['userName']")" = "ana" ] && ok "1.5 user segment carries the role field" || bad "1.5 user segment wrong — $RESP"
[ "$(jsonq "d['data'][0]['user']['emailNotification']")" = "True" ] && ok "1.6 user sibling renders FLAT in the segment" || bad "1.6 sibling missing — $RESP"
[ "$(jsonq "'employee' in d['data'][0]")" = "False" ] && ok "1.7 absent role omits its key (null segment)" || bad "1.7 employee key must be absent — $RESP"

title "1.8 by-id (the person id IS the shared-PK role id)"
req GET "/persons/$USER_ID"
expect_status "GET /persons/:id" 200
[ "$(jsonq "d['data']['document']")" = "$D1" ] && ok "1.9 by-id returns the composed identity" || bad "1.9 by-id wrong — $RESP"
req GET "/persons/00000000-0000-0000-0000-000000000000"
expect_status "1.10 unknown id → 404" 404
req GET "/persons/$USER_ID?bogus=1"
expect_status "1.11 undeclared by-id query key → 400" 400

####################################
sec "2. Second role on the same document: two segments, one identity"
####################################
req POST /employees "{\"name\":\"Ana Souza\",\"email\":\"ana@example.com\",\"document\":\"$D1\",\"employeeNumber\":\"EMP-1\",\"bank\":\"260\",\"branch\":\"0001\",\"account\":\"12345-6\",\"dependents\":[{\"name\":\"Rita\",\"birthDate\":\"2015-03-10T00:00:00Z\",\"relationship\":\"daughter\",\"healthPlanProvider\":\"Unimed\",\"healthPlanCard\":\"UN-1\"}],\"jobHistories\":[{\"jobTitle\":\"Engineer\",\"department\":\"Platform\",\"hiredAt\":\"2022-01-10T00:00:00Z\"}],\"addresses\":[{\"street\":\"Rua A\",\"number\":\"1\",\"neighborhood\":\"Centro\",\"city\":\"POA\",\"state\":\"RS\",\"zipCode\":\"90000000\",\"country\":\"BR\"}]}"
expect_status "2.1 POST /employees (same document)" 201

wait_person "document=$D1" "'employee' in d['data'][0] and d['data'][0]['employee'].get('employeeNumber') == 'EMP-1'" && \
  ok "2.2 employee segment appeared on the SAME person doc" || bad "2.2 employee segment never appeared"
req GET "/persons?document=$D1&onlyTotal=true"
[ "$(jsonq "d['pagination']['total']")" = "1" ] && ok "2.3 still ONE person (dedup by document)" || bad "2.3 duplicated identity — $RESP"
req GET "/persons?document=$D1"
[ "$(jsonq "len(d['data'][0]['addresses'])")" = "1" ] && ok "2.4 re-sent identical address deduped at the root" || bad "2.4 addresses duplicated — $RESP"
[ "$(jsonq "d['data'][0]['employee']['bank']")" = "260" ] && ok "2.5 bank sibling FLAT inside the employee segment" || bad "2.5 bank sibling missing — $RESP"
[ "$(jsonq "len(d['data'][0]['employee']['dependents'])")" = "1" ] && ok "2.6 dependents nest INSIDE the segment" || bad "2.6 dependents missing — $RESP"
[ "$(jsonq "d['data'][0]['employee']['dependents'][0]['healthPlanProvider']")" = "Unimed" ] && ok "2.7 child-sibling fields flat in the child" || bad "2.7 plan fields missing — $RESP"
[ "$(jsonq "len(d['data'][0]['employee']['jobHistories'])")" = "1" ] && ok "2.8 jobHistories nest INSIDE the segment" || bad "2.8 jobHistories missing — $RESP"
[ "$(jsonq "'name' in d['data'][0]['employee']")" = "False" ] && ok "2.9 base fields never repeat inside a segment" || bad "2.9 base fields leaked into the segment — $RESP"

####################################
sec "3. Cross-role convergence on the person root"
####################################
req PATCH "/employees/$USER_ID" '{"name":"Ana Maria Souza"}'
expect_status "3.1 PATCH /employees (shared field through the employee)" 200
wait_person "document=$D1" "d['data'][0]['name'] == 'Ana Maria Souza'" && \
  ok "3.2 person root converged from the employee write" || bad "3.2 root name did not converge"

req PATCH "/users/$USER_ID" '{"name":"Ana M. Souza"}'
expect_status "3.3 PATCH /users (shared field through the user)" 200
wait_person "document=$D1" "d['data'][0]['name'] == 'Ana M. Souza'" && \
  ok "3.4 person root converged from the user write" || bad "3.4 root name did not converge"

title "3.5 base children edited through a role reflect at the person ROOT"
req PUT "/users/$USER_ID" '{"name":"Ana M. Souza","email":"ana@example.com","phone":null,"userName":"ana","emailNotification":true,"smsNotification":null,"addresses":[{"street":"Rua A","number":"1","label":null,"complement":null,"neighborhood":"Centro","city":"POA","state":"RS","zipCode":"90000000","country":"BR"},{"street":"Av B","number":"2","label":null,"complement":null,"neighborhood":"Norte","city":"POA","state":"RS","zipCode":"91000000","country":"BR"}]}'
expect_status "3.5 PUT /users adds a second address" 200
wait_person "document=$D1" "len(d['data'][0]['addresses']) == 2" && \
  ok "3.6 person root gained the address added through the USER role" || bad "3.6 addresses did not converge to 2"

req PUT "/employees/$USER_ID" '{"name":"Ana M. Souza","email":"ana@example.com","phone":null,"employeeNumber":"EMP-1","bank":"260","branch":"0001","account":"12345-6","pix":null,"dependents":[{"name":"Rita","birthDate":"2015-03-10T00:00:00Z","relationship":"daughter","healthPlanProvider":"Unimed","healthPlanCard":"UN-1","healthPlanExpiry":null}],"jobHistories":[{"jobTitle":"Engineer","department":"Platform","hiredAt":"2022-01-10T00:00:00Z","terminatedAt":null}],"addresses":[{"street":"Rua A","number":"1","label":null,"complement":null,"neighborhood":"Centro","city":"POA","state":"RS","zipCode":"90000000","country":"BR"}]}'
expect_status "3.7 PUT /employees trims addresses back to one" 200
wait_person "document=$D1" "len(d['data'][0]['addresses']) == 1" && \
  ok "3.8 person root lost the address removed through the EMPLOYEE role" || bad "3.8 addresses did not converge back to 1"

title "3.9 a ROLE SIBLING change lands inside its segment"
req PATCH "/users/$USER_ID" '{"emailNotification":false}'
expect_status "3.9 PATCH /users flips the notification sibling" 200
wait_person "document=$D1" "d['data'][0]['user'].get('emailNotification') == False" && \
  ok "3.10 user segment reflects the sibling change" || bad "3.10 sibling change did not reach the segment"

####################################
sec "4. Role-path filters — the FULL declared vocabulary + the exact allowlist"
####################################
req POST /users "{\"name\":\"Beto Lima\",\"email\":\"beto@example.com\",\"document\":\"$D2\",\"userName\":\"beto\"}"
expect_status "4.0 second person (user-only)" 201
wait_person "document=$D2&onlyTotal=true" "d['pagination']['total'] == 1" || bad "4.0 second person never materialized"

# one(<label> <qs> [expected]) — the filtered list returns exactly N (default 1).
one() {
  local label="$1" qs="$2" expected="${3:-1}"
  req GET "/persons?$qs&onlyTotal=true"
  [ "$(jsonq "d['pagination']['total']")" = "$expected" ] && ok "$label" || bad "$label (total=$(jsonq "d['pagination']['total']"), want $expected) — $qs"
}

title "4.1 root fields — every declared operator"
one "4.1.1 name eq"                "name=Ana%20M.%20Souza"
one "4.1.2 name startswith"        "name.startswith=Ana"
one "4.1.3 name icontains"         "name.icontains=souza"
one "4.1.4 name istartswith"       "name.istartswith=ana"
one "4.1.5 email eq"               "email=ana@example.com"
one "4.1.6 email in"               "email.in=ana@example.com,none@x"
one "4.1.7 email ieq"              "email.ieq=ANA@EXAMPLE.COM"
one "4.1.8 document eq"            "document=$D1"
one "4.1.9 document in (both)"     "document.in=$D1,$D2" 2
one "4.1.10 document startswith"   "document.startswith=70000" 2

title "4.2 base-child paths (addresses.*)"
one "4.2.1 addresses.city eq"          "addresses.city=POA"
one "4.2.2 addresses.city istartswith" "addresses.city.istartswith=po"
one "4.2.3 addresses.city icontains"   "addresses.city.icontains=oa"
one "4.2.4 addresses.state eq"         "addresses.state=RS"
one "4.2.5 addresses.state in"         "addresses.state.in=RS,SC"
one "4.2.6 addresses.country eq"       "addresses.country=BR"
one "4.2.7 addresses.country in"       "addresses.country.in=BR,US"
one "4.2.8 addresses.zipCode eq"       "addresses.zipCode=90000000"
one "4.2.9 addresses.zipCode startswith" "addresses.zipCode.startswith=9000"

title "4.3 user segment paths"
one "4.3.1 user.userName eq"          "user.userName=ana"
one "4.3.2 user.userName in (both)"   "user.userName.in=ana,beto" 2
one "4.3.3 user.userName istartswith" "user.userName.istartswith=AN"
one "4.3.4 user.emailNotification eq (bool, flipped in 3.9)" "user.emailNotification=false"

title "4.4 employee segment paths (role field + sibling + children + child-sibling)"
one "4.4.1 employee.employeeNumber eq"       "employee.employeeNumber=EMP-1"
one "4.4.2 employee.employeeNumber in"       "employee.employeeNumber.in=EMP-1,EMP-9"
one "4.4.3 employee.employeeNumber startswith" "employee.employeeNumber.startswith=EMP"
one "4.4.4 employee.bank eq (role sibling)"  "employee.bank=260"
one "4.4.5 employee.bank in"                 "employee.bank.in=260,001"
one "4.4.6 dependents.name eq"               "employee.dependents.name=Rita"
one "4.4.7 dependents.name istartswith"      "employee.dependents.name.istartswith=ri"
one "4.4.8 dependents.name icontains"        "employee.dependents.name.icontains=IT"
one "4.4.9 dependents.relationship eq"       "employee.dependents.relationship=daughter"
one "4.4.10 dependents.relationship in"      "employee.dependents.relationship.in=daughter,son"
one "4.4.11 dependents.healthPlanProvider eq (child sibling)" "employee.dependents.healthPlanProvider=Unimed"
one "4.4.12 dependents.healthPlanProvider in" "employee.dependents.healthPlanProvider.in=Unimed,Amil"
one "4.4.13 jobHistories.jobTitle eq"        "employee.jobHistories.jobTitle=Engineer"
one "4.4.14 jobHistories.jobTitle istartswith" "employee.jobHistories.jobTitle.istartswith=eng"
one "4.4.15 jobHistories.jobTitle icontains" "employee.jobHistories.jobTitle.icontains=gine"
one "4.4.16 jobHistories.department eq"      "employee.jobHistories.department=Platform"
one "4.4.17 jobHistories.department in"      "employee.jobHistories.department.in=Platform,Core"

title "4.5 negative matches + text search + onlyTotal"
one "4.5.1 non-matching role filter → 0"  "user.userName=nobody" 0
one "4.5.2 non-matching child path → 0"   "employee.dependents.relationship=spouse" 0
one "4.5.3 \$text search hits"            "search=Souza"
req GET "/persons?document=$D1&onlyTotal=true"
[ "$(jsonq "d['pagination']['total'] == 1 and len(d.get('data', [])) == 0")" = "True" ] && \
  ok "4.5.4 onlyTotal returns the count with no data page" || bad "4.5.4 — $RESP"

title "4.6 the exact allowlist"
req GET "/persons?bogusKey=1"
expect_status "4.6.1 undeclared filter key → 400" 400
req GET "/persons?user.bogus=1"
expect_status "4.6.2 undeclared role sub-key → 400" 400
req GET "/persons?name.gte=A"
expect_status "4.6.3 undeclared OPERATOR on a declared key → 400" 400
req GET "/persons?employee.dependents.name.gte=A"
expect_status "4.6.4 undeclared operator on a role-child path → 400" 400

####################################
sec "5. Sort + sparse render + KEYSET CURSOR pagination"
####################################
req POST /users "{\"name\":\"Caio Prado\",\"email\":\"caio@example.com\",\"document\":\"70000000003\",\"userName\":\"caio\"}"
expect_status "5.0 third person (for pagination)" 201
wait_person "onlyTotal=true" "d['pagination']['total'] == 3" || bad "5.0 third person never materialized"

req GET "/persons?sort=name"
[ "$(jsonq "[p['name'] for p in d['data']] == sorted([p['name'] for p in d['data']])")" = "True" ] && ok "5.1 ?sort=name ascending" || bad "5.1 — $RESP"
req GET "/persons?sort=-name"
[ "$(jsonq "[p['name'] for p in d['data']] == sorted([p['name'] for p in d['data']], reverse=True)")" = "True" ] && ok "5.2 ?sort=-name descending" || bad "5.2 — $RESP"
req GET "/persons?document=$D1&fields=name,user.userName"
[ "$(jsonq "d['data'][0]['user']['userName'] == 'ana' and 'email' not in d['data'][0] and 'employee' not in d['data'][0]")" = "True" ] && \
  ok "5.3 ?fields= sparse render through the role segment" || bad "5.3 — $RESP"
req GET "/persons?document=$D1&fields=name,employee.dependents.name"
[ "$(jsonq "d['data'][0]['employee']['dependents'][0]['name'] == 'Rita' and 'user' not in d['data'][0]")" = "True" ] && \
  ok "5.4 ?fields= narrows down to a role-CHILD subfield" || bad "5.4 — $RESP"

title "5.5 forward cursor (limit=2 → follow next_cursor)"
req GET "/persons?limit=2&sort=name"
[ "$(jsonq "d['pagination']['has_next']")" = "True" ] && ok "5.5.1 page 1 has_next=true" || bad "5.5.1 — $RESP"
P1_LAST=$(jsonq "d['data'][-1]['id']")
CURSOR=$(jsonq "d['pagination']['next_cursor']")
req GET "/persons?limit=2&sort=name&after=$CURSOR"
P2_FIRST=$(jsonq "d['data'][0]['id']")
if [ -n "$P2_FIRST" ] && [ "$P2_FIRST" != "$P1_LAST" ] && [ "$(jsonq "len(d['data'])")" = "1" ]; then
  ok "5.5.2 next_cursor advances (page 2 = the remaining 1 doc, no overlap)"
else
  bad "5.5.2 cursor page wrong (p1_last=$P1_LAST p2_first=$P2_FIRST) — $RESP"
fi
[ "$(jsonq "d['pagination']['has_prev']")" = "True" ] && ok "5.5.3 page 2 has_prev=true" || bad "5.5.3 — $RESP"
[ "$(jsonq "d['pagination']['has_next']")" = "False" ] && ok "5.5.4 page 2 has_next=false (end of set)" || bad "5.5.4 — $RESP"

title "5.6 backward cursor (?before= walks back to page 1)"
PREV=$(jsonq "d['pagination']['prev_cursor']")
req GET "/persons?limit=2&sort=name&before=$PREV"
[ "$(jsonq "len(d['data']) == 2 and d['data'][-1]['id'] == '$P1_LAST'")" = "True" ] && \
  ok "5.6.1 before-cursor returns page 1 (canonical order preserved)" || bad "5.6.1 — $RESP"

title "5.7 cursor context binding (changed criteria → 400)"
req GET "/persons?limit=2&sort=-name&after=$CURSOR"
expect_status "5.7.1 reusing a cursor under a DIFFERENT sort → 400" 400

####################################
sec "6. Role lifecycle on the segment (person survives via the other role)"
####################################
req PATCH "/employees/$USER_ID/archive"
expect_status "6.1 archive the employee role" 204
wait_person "document=$D1" "'employee' not in d['data'][0]" && \
  ok "6.2 archived role hidden on the default read" || bad "6.2 employee segment still visible"
req GET "/persons?document=$D1&includeArchived=true"
[ "$(jsonq "d['data'][0]['employee'].get('deletedAt') is not None")" = "True" ] && \
  ok "6.3 ?includeArchived surfaces the archived segment WITH deletedAt" || bad "6.3 — $RESP"
req GET "/persons?document=$D1&onlyTotal=true"
[ "$(jsonq "d['pagination']['total']")" = "1" ] && ok "6.4 person stays visible (user role still active)" || bad "6.4 — $RESP"

req PATCH "/employees/$USER_ID/unarchive"
expect_status "6.5 unarchive the employee role" 204
wait_person "document=$D1" "d['data'][0].get('employee', {}).get('employeeNumber') == 'EMP-1'" && \
  ok "6.6 revived segment back on the default read" || bad "6.6 segment did not revive"

####################################
sec "7. Base convergence: last active role archives → person hides at the root"
####################################
req PATCH "/employees/$USER_ID/archive"
expect_status "7.1 archive employee again" 204
req PATCH "/users/$USER_ID/archive"
expect_status "7.2 archive the LAST active role (user)" 204
wait_person "document=$D1&onlyTotal=true" "d['pagination']['total'] == 0" && \
  ok "7.3 person hidden at the root (base converged to archived)" || bad "7.3 person still listed"
req GET "/persons/$USER_ID"
expect_status "7.4 by-id hidden too" 404
req GET "/persons?document=$D1&includeArchived=true&onlyTotal=true"
[ "$(jsonq "d['pagination']['total']")" = "1" ] && ok "7.5 ?includeArchived surfaces the archived person" || bad "7.5 — $RESP"
req GET "/persons/$USER_ID?includeArchived=true"
expect_status "7.6 by-id with includeArchived" 200

req PATCH "/users/$USER_ID/unarchive"
expect_status "7.7 unarchive one role" 204
wait_person "document=$D1&onlyTotal=true" "d['pagination']['total'] == 1" && \
  ok "7.8 person revived with its first active role" || bad "7.8 person did not revive"

####################################
sec "8. Hard-delete of ONE role: the segment vanishes (payload-FK recompose)"
####################################
# The employee is still ARCHIVED from 7.1 — and an archived row is invisible
# to the DELETE's load-first read (soft-delete is delete). Revive it first.
req PATCH "/employees/$USER_ID/unarchive"
expect_status "8.0 unarchive the employee (archived rows cannot be hard-deleted)" 204
req DELETE "/employees/$USER_ID"
expect_status "8.1 DELETE /employees (user still references the person)" 204
wait_person "document=$D1&includeArchived=true" "'employee' not in d['data'][0]" && \
  ok "8.2 deleted role's segment gone even with includeArchived (row is GONE)" || bad "8.2 employee segment survived the delete"
req GET "/persons?document=$D1&onlyTotal=true"
[ "$(jsonq "d['pagination']['total']")" = "1" ] && ok "8.3 person survives through the user role" || bad "8.3 — $RESP"

####################################
sec "9. Hard-delete of the LAST role: the identity purges, the doc is removed"
####################################
req DELETE "/users/$USER_ID"
expect_status "9.1 DELETE /users (last role → orphan purge)" 204
wait_person "document=$D1&includeArchived=true&onlyTotal=true" "d['pagination']['total'] == 0" && \
  ok "9.2 person doc REMOVED (purge convergence — not archived, gone)" || bad "9.2 person doc survived the purge"

####################################
sec "10. Exports: hierarchical role branches"
####################################
CSV=$(curl -sS "$BASE/persons.csv?document=$D2" -H "Accept-Language: en-US")
echo "$CSV" | head -1 | grep -q "Document" && ok "10.1 CSV root header carries base columns" || bad "10.1 CSV header — $(echo "$CSV" | head -1)"
echo "$CSV" | grep -q "beto" && ok "10.2 CSV carries the user role branch (userName value)" || bad "10.2 CSV role branch missing"
XLSX_MAGIC=$(curl -sS "$BASE/persons.xlsx?document=$D2" | head -c 2)
[ "$XLSX_MAGIC" = "PK" ] && ok "10.3 XLSX responds with a ZIP container" || bad "10.3 XLSX magic bytes = $XLSX_MAGIC"

####################################
sec "11. GraphQL persons connection"
####################################
req POST /graphql "{\"query\":\"{ persons(where: {document: {eq: \\\"$D2\\\"}}) { totalCount edges { node { name document user { userName } } } } }\"}"
expect_status "11.1 GraphQL persons query" 200
[ "$(jsonq "d['data']['persons']['totalCount']")" = "1" ] && ok "11.2 totalCount" || bad "11.2 — $RESP"
[ "$(jsonq "d['data']['persons']['edges'][0]['node']['user']['userName']")" = "beto" ] && \
  ok "11.3 role sub-object through GraphQL" || bad "11.3 — $RESP"

####################################
hr
printf '\033[1;37mperson.sh done — PASS=%d FAIL=%d (backend=%s)\033[0m\n' "$PASS" "$FAIL" "$BACKEND"
[ "$FAIL" -eq 0 ]
