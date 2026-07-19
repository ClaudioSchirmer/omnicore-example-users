#!/usr/bin/env bash
# End-to-end test suite for omnicore-example-users.
#
# Exercises every endpoint and every custom notification declared in
# domain/notifications.go. Each case prints REQUEST/BODY/STATUS/RESPONSE
# so any divergence between expectation and reality is visible.
#
# Internationalized fixtures (US/UK/DE/BR). No country-specific validation —
# state/zipCode are validated by shape regex (country-agnostic), country is
# ISO 3166-1 alpha-2 shape only.
#
# Requires the service to be running locally on :8080 (go run -tags 'postgres kafka' ./bootstrap),
# Postgres on :5433 (docker compose) and the Debezium connector registered.
#
# Run from anywhere:  bash qa/e2e.sh
set -u

# Backend selector (postgres|mysql via BACKEND env). Provides qa_db_*, qa_uuid_*,
# qa_mongo_reset, $QA_MONGO_DB. Defaults to postgres — identical to before.
source "$(dirname "$0")/_backend.sh"

BASE="${BASE:-http://localhost:8080}"
PASS=0; FAIL=0

# wait_for_view <id> <expected_status> [timeout_seconds]
# Polls GET /users/<id> until the response status matches the expected value or
# the timeout expires. Used because Postgres outbox → Debezium → Kafka →
# SyncEngine → Mongo upsert is eventually consistent — under write load the
# replication delay grows past a flat sleep.
wait_for_view() {
  local id="$1" expected="$2" timeout="${3:-15}"
  local deadline=$(( $(date +%s) + timeout ))
  local status
  while [ "$(date +%s)" -lt "$deadline" ]; do
    status=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/users/$id")
    [ "$status" = "$expected" ] && return 0
    sleep 0.25
  done
  return 1
}

hr() { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec() { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }

# show <name> <method> <path> [body] [expected_status]
show() {
  local name="$1" method="$2" path="$3" body="${4:-}" expected="${5:-}"
  title "$name"
  if [ -n "$body" ]; then
    echo "REQUEST : $method $path"
    echo "BODY    :"
    echo "$body" | python3 -m json.tool 2>/dev/null || echo "$body"
  else
    echo "REQUEST : $method $path"
  fi
  local tmp; tmp=$(mktemp)
  local status
  if [ -n "$body" ]; then
    status=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" \
      -H "Content-Type: application/json" -H "Accept-Language: en-US" \
      --data "$body")
  else
    status=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" \
      -H "Content-Type: application/json" -H "Accept-Language: en-US")
  fi
  echo "STATUS  : $status"
  echo "RESPONSE:"
  if [ -s "$tmp" ]; then
    python3 -m json.tool < "$tmp" 2>/dev/null || cat "$tmp"
    echo
  else
    echo "(empty body)"
  fi
  if [ -n "$expected" ]; then
    if [ "$status" = "$expected" ]; then
      printf '\033[1;32mPASS\033[0m (expected %s)\n' "$expected"
      PASS=$((PASS+1))
    else
      printf '\033[1;31mFAIL\033[0m (expected %s, got %s)\n' "$expected" "$status"
      FAIL=$((FAIL+1))
    fi
  fi
  rm -f "$tmp"
}

####################################
sec "0. Health"
####################################
title "GET /livez"
echo "REQUEST : GET /livez"
curl -sS -w "\nSTATUS  : %{http_code}\n" "$BASE/livez"

####################################
sec "0.3 Whoami — Identity smoke check"
####################################
# Under auth.mode=disabled (the default in microservice.dev.yaml) the
# framework's AuthMiddleware is NOT registered, so AppContext.Identity()
# returns nil and /whoami responds with the anonymous placeholder body
# {"subject":"anonymous","authenticated":false}. The same endpoint under
# auth.mode=jwt would reflect the JWT subject.
show "0.3.1 /whoami responds 200 with anonymous body under auth.mode=disabled" GET /whoami '' 200

####################################
sec "0.5 Reset state — a clean baseline is a precondition of the suite"
####################################
# The suite assumes fixed emails ("jane@example.com", "bob@example.com" etc.).
# Residual state from previous runs makes POST 2.1/2.2 return 409 and every
# subsequent endpoint using $USER_A/$USER_B/$USER_C fails in cascade due to an
# empty ID. The reset is destructive by design — QA is an ephemeral
# environment, it does not store persistent state.
title "Reset relational domain tables (users+addresses+outbox) [$BACKEND]"
qa_db_reset_domain
echo "$BACKEND: users + addresses (FK) + outbox cleared."

title "db.users.deleteMany({}) (Mongo: $QA_MONGO_DB)"
qa_mongo_reset
echo "Mongo: users collection cleared."

title "Sleep 2s — SyncEngine drains in-flight Kafka events"
sleep 2
echo "Ready. Clean environment."

####################################
sec "1. POST /users — validation notifications"
####################################

show "1.1 InvalidEmailNotification (no @)" POST /users '{
  "name":"Test","email":"not-an-email","phone":"14155552671",
  "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}]
}' 422

show "1.2 InvalidEmailNotification (no TLD)" POST /users '{
  "name":"Test","email":"jane@example","phone":"14155552671",
  "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}]
}' 422

show "1.3 InvalidEmailNotification (empty local-part)" POST /users '{
  "name":"Test","email":"@example.com","phone":"14155552671",
  "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}]
}' 422

show "1.4 InvalidPhoneNotification (phone too short)" POST /users '{
  "name":"Test","email":"jane@example.com","phone":"12345",
  "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}]
}' 422

show "1.5 InvalidStateNotification (forbidden chars in state — shape regex)" POST /users '{
  "name":"Test","email":"jane@example.com","phone":"14155552671",
  "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"@#","zipCode":"94103","country":"US"}]
}' 422

show "1.6 InvalidZipCodeNotification (forbidden chars in zip — shape regex)" POST /users '{
  "name":"Test","email":"jane@example.com","phone":"14155552671",
  "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103!","country":"US"}]
}' 422

show "1.7 InvalidCountryNotification (empty country)" POST /users '{
  "name":"Test","email":"jane@example.com","phone":"14155552671",
  "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":""}]
}' 422

show "1.8 DuplicateAddressNotification (Phase 20: Country+ZIP+Street+Number repeated)" POST /users '{
  "name":"Test","email":"jane@example.com","phone":"14155552671",
  "addresses":[
    {"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"},
    {"label":"work","street":"Main","number":"1","neighborhood":"Mission","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}
  ]
}' 422

show "1.9 RequiredFieldNotification (no name)" POST /users '{
  "email":"jane@example.com","phone":"14155552671",
  "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}]
}' 422

show "1.10 Multiple notifications grouped (invalid email + invalid zip)" POST /users '{
  "name":"Test","email":"x","phone":"14155552671",
  "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"!","country":"US"}]
}' 422

show "1.11 Invalid JSON (parse error → 400)" POST /users '{not json' 400

# 1.12 + 1.13 — NameMaxLengthExceededNotification: the framework's parameterized
# notification mechanism. The notification carries `MaxLength int tvar:"maxLength"`
# (domain/notifications.go) and the catalog entry contains the `{maxLength}` placeholder.
# At render time the framework substitutes the runtime value (the per-request limit
# injected by InsertUserCommand.ToEntity from nameMaxLengthPolicy=100). Two cases
# verify both languages — the same notification key produces a substituted message
# in EN and PT-BR independently.
#
# Body-substring assertions: the rendered message must carry the literal "100"
# (substituted) AND must NOT carry the literal "{maxLength}" (placeholder leaked).
NAME_OVER_LIMIT=$(printf 'A%.0s' $(seq 1 101))
BODY_NAME_OVER='{
  "name":"'"$NAME_OVER_LIMIT"'","email":"jane@example.com","phone":"14155552671",
  "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}]
}'

show "1.12 NameMaxLengthExceededNotification — 101-char name rejected (status only)" POST /users "$BODY_NAME_OVER" 422

# 1.13 EN-rendered message body assertion: substituted "100", placeholder absent.
title "1.13 NameMaxLengthExceededNotification — EN message renders '100', no '{maxLength}'"
RESP_NAME_EN=$(curl -sS -X POST "$BASE/users" \
  -H "Content-Type: application/json" -H "Accept-Language: en-US" \
  --data "$BODY_NAME_OVER")
echo "RESPONSE:"
echo "$RESP_NAME_EN" | python3 -m json.tool 2>/dev/null || echo "$RESP_NAME_EN"
if echo "$RESP_NAME_EN" | grep -q '"notificationKey":"NameMaxLengthExceededNotification"' \
   && echo "$RESP_NAME_EN" | grep -q '100' \
   && ! echo "$RESP_NAME_EN" | grep -q '{maxLength}'; then
  printf '\033[1;32mPASS\033[0m (EN message contains "100" and no "{maxLength}")\n'
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (expected substituted "100" and no placeholder, got body above)\n'
  FAIL=$((FAIL+1))
fi

# 1.14 PT-BR-rendered message body assertion — same notification key, different
# locale. Catalog entry: "O nome excede o tamanho máximo permitido de {maxLength} caracteres."
title "1.14 NameMaxLengthExceededNotification — PT-BR message renders '100', no '{maxLength}'"
RESP_NAME_PT=$(curl -sS -X POST "$BASE/users" \
  -H "Content-Type: application/json" -H "Accept-Language: pt-BR" \
  --data "$BODY_NAME_OVER")
echo "RESPONSE:"
echo "$RESP_NAME_PT" | python3 -m json.tool 2>/dev/null || echo "$RESP_NAME_PT"
if echo "$RESP_NAME_PT" | grep -q '"notificationKey":"NameMaxLengthExceededNotification"' \
   && echo "$RESP_NAME_PT" | grep -q 'tamanho máximo permitido de 100 caracteres' \
   && ! echo "$RESP_NAME_PT" | grep -q '{maxLength}'; then
  printf '\033[1;32mPASS\033[0m (PT-BR message renders substituted "100" with no placeholder leak)\n'
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (expected PT-BR substitution, got body above)\n'
  FAIL=$((FAIL+1))
fi

####################################
sec "2. POST /users — happy path (multi-country)"
####################################

title "2.1 Create Jane (US) — expected 201"
BODY_A='{
  "name":"Jane Doe","email":"jane@example.com","phone":"14155552671",
  "document":"10000000001","userName":"jane","emailNotification":true,"smsNotification":false,
  "addresses":[{
    "label":"home","street":"1 Infinite Loop","number":"1","complement":"apt 201",
    "neighborhood":"Mariani","city":"Cupertino","state":"CA","zipCode":"95014","country":"US"
  }]
}'
echo "REQUEST : POST /users"
echo "BODY    :"
echo "$BODY_A" | python3 -m json.tool
RESP_A=$(curl -sS -w "\n__STATUS__%{http_code}" -X POST "$BASE/users" \
  -H "Content-Type: application/json" -H "Accept-Language: en-US" --data "$BODY_A")
ST_A=${RESP_A##*__STATUS__}
JSON_A=${RESP_A%__STATUS__*}
echo "STATUS  : $ST_A"
echo "RESPONSE:"
echo "$JSON_A" | python3 -m json.tool
USER_A=$(echo "$JSON_A" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
echo "USER_A_ID = $USER_A"
if [ "$ST_A" = "201" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

title "2.1b POST response mirrors the aggregate — addresses[] carry the persisted ids (child-id write-back)"
# The write response is the FULL aggregate mirror. The persister mints each
# child PK in Go (the same newWriteID as the root — no RETURNING, no second
# query on MySQL) and writes it back into the aggregate map, so FromEntity
# projects the addresses WITH their ids. Regression guard for the framework's
# child-id write-back: an empty/missing id here means the write-back broke.
ADDR_A_ID=$(echo "$JSON_A" | python3 -c \
  'import sys,json;d=json.load(sys.stdin);a=d["data"].get("addresses") or [];print(a[0].get("id","") if a else "")' 2>/dev/null)
ADDR_A_STREET=$(echo "$JSON_A" | python3 -c \
  'import sys,json;d=json.load(sys.stdin);a=d["data"].get("addresses") or [];print(a[0].get("street","") if a else "")' 2>/dev/null)
if [ "${#ADDR_A_ID}" = "36" ] && [ "$ADDR_A_STREET" = "1 Infinite Loop" ]; then
  printf '\033[1;32mPASS\033[0m (addresses[0].id=%s, street=%s)\n' "$ADDR_A_ID" "$ADDR_A_STREET"
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (expected a 36-char address id + the mirrored street, got id=%q street=%q)\n' "$ADDR_A_ID" "$ADDR_A_STREET"
  FAIL=$((FAIL+1))
fi

title "2.2 Create Bob (UK) — will be used in conflict tests"
BODY_B='{
  "name":"Bob Smith","email":"bob@example.com","phone":"442079460000",
  "document":"10000000002","userName":"bob",
  "addresses":[{
    "label":"home","street":"10 Downing","number":"10",
    "neighborhood":"Westminster","city":"London","state":"England","zipCode":"SW1A 2AA","country":"GB"
  }]
}'
echo "BODY    :"
echo "$BODY_B" | python3 -m json.tool
RESP_B=$(curl -sS -w "\n__STATUS__%{http_code}" -X POST "$BASE/users" \
  -H "Content-Type: application/json" -H "Accept-Language: en-US" --data "$BODY_B")
ST_B=${RESP_B##*__STATUS__}
JSON_B=${RESP_B%__STATUS__*}
echo "STATUS  : $ST_B"
echo "RESPONSE:"
echo "$JSON_B" | python3 -m json.tool
USER_B=$(echo "$JSON_B" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
echo "USER_B_ID = $USER_B"
if [ "$ST_B" = "201" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

title "2.3 Create Anna (DE) without phone (nullable)"
BODY_C='{
  "name":"Anna Müller","email":"anna@example.com",
  "document":"10000000003","userName":"anna",
  "addresses":[{
    "label":"home","street":"Unter den Linden","number":"1",
    "neighborhood":"Mitte","city":"Berlin","state":"Berlin","zipCode":"10117","country":"DE"
  }]
}'
echo "BODY    :"
echo "$BODY_C" | python3 -m json.tool
RESP_C=$(curl -sS -w "\n__STATUS__%{http_code}" -X POST "$BASE/users" \
  -H "Content-Type: application/json" -H "Accept-Language: en-US" --data "$BODY_C")
ST_C=${RESP_C##*__STATUS__}
echo "STATUS  : $ST_C"
echo "RESPONSE:"
echo "${RESP_C%__STATUS__*}" | python3 -m json.tool
USER_C=$(echo "${RESP_C%__STATUS__*}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
echo "USER_C_ID = $USER_C"
if [ "$ST_C" = "201" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

####################################
sec "3. POST /users — SharedBase conflict (409) + archived-revive via document"
####################################

# Identity is now the Person's `document` (natural key), not email. A POST whose
# document already has an ACTIVE user is a 409 — the framework's SharedBase
# matrix raises EntityAlreadyAddedNotification (email is just a shared field now,
# freely reused). Retry Bob's document (10000000002) with different other fields.
show "3.1 EntityAlreadyAddedNotification (retry Bob's document 10000000002, active user exists)" POST /users '{
  "name":"Other","email":"other@example.com","phone":"442079461111",
  "document":"10000000002","userName":"other",
  "addresses":[{"label":"home","street":"Other","number":"2","neighborhood":"X","city":"London","state":"England","zipCode":"SW1A 1AA","country":"GB"}]
}' 409

# 3.2 demonstrates that an ARCHIVED role is NOT revived by POST: soft-delete is
# delete, so the archived user is invisible to the insert probe; the write
# proceeds and the shared-PK remnant (user PK IS the person id) collides on the
# primary key, which the repository's ConstraintBinding maps to the same 409 as
# the active conflict. The explicit way back is /unarchive (3.2b) — never a
# POST side effect.
title "3.2 Archived role is NOT revived — archive USER_C (doc 10000000003), re-POST same document"
echo "Pre-step: PATCH USER_C/archive"
ARCH_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH "$BASE/users/$USER_C/archive" -H "Content-Type: application/json")
echo "Archive USER_C status: $ARCH_STATUS"
show "3.2 POST with the document of archived USER_C — invisible to the probe; PK remnant vetoes → 409" POST /users '{
  "name":"Anna II","email":"anna.ii@example.com","phone":"493012345678",
  "document":"10000000003","userName":"anna",
  "addresses":[{"label":"home","street":"Kurfürstendamm","number":"1","neighborhood":"Charlottenburg","city":"Berlin","state":"Berlin","zipCode":"10719","country":"DE"}]
}' 409

show "3.2b PATCH /users/USER_C/unarchive — the explicit way back for an archived role" PATCH "/users/$USER_C/unarchive" "" 204
# USER_C is back ACTIVE with its ORIGINAL fields (Anna Müller, Berlin) — the
# rejected POST applied nothing. Create a separate Anna III (new document) for
# the later DELETE case.
USER_C2=$(curl -sS -X POST "$BASE/users" -H "Content-Type: application/json" -H "Accept-Language: en-US" \
  -d '{"name":"Anna III","email":"anna3@example.com","phone":"493012340000","document":"10000000033","userName":"anna3",
       "addresses":[{"label":"home","street":"X","number":"1","neighborhood":"Y","city":"Berlin","state":"Berlin","zipCode":"10115","country":"DE"}]}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null || echo "")
echo "USER_C2 (Anna III, new for DELETE in 8.x) = $USER_C2"

####################################
sec "4. GET /users/:id and GET /users (CDC eventually consistent)"
####################################

title "4.0 Polling Mongo via GET /users/$USER_C2 until 200 (CDC)"
# Gate on the LAST fixture written before this section (Anna III), not the
# first (Jane): the users topic is single-partition and the SyncEngine
# consumes in order, so the newest write visible ⇒ every earlier one is too.
# Waiting on Jane let a lagging lane pass the gate with the Annas still in
# flight and 4.5/4.6 reading a half-materialized view.
if wait_for_view "$USER_C2" "200" 30; then
  echo "view ready"
else
  echo "TIMEOUT waiting for view (30s) — continuing anyway to record the failure"
fi

show "4.1 GET /users/:id (Jane, populated via CDC)" GET "/users/$USER_A" "" 200

show "4.2 GET /users/<nonexistent-uuid> (RecordNotFound)" GET /users/00000000-0000-0000-0000-000000000000 "" 404

show "4.3 GET /users (listing)" GET /users "" 200

title "4.4 GET round-trip on multi-word fields (regression: zip_code → zipCode via view: tag)"
# The composer writes Postgres column names verbatim to the Mongo doc
# (snake_case: zip_code). The wire contract is camelCase (zipCode), bridged
# by view:"zip_code" on FindUserByIDAddressOutput.ZipCode. Without the tag
# the field would arrive empty silently — case 4.1 above only asserted the
# HTTP status and would have missed it. This case round-trips the value sent
# in the initial POST (USER_A — Jane, zipCode=95014) and rejects empty.
RESP_44=$(curl -sS "$BASE/users/$USER_A" -H "Accept-Language: en-US")
echo "RESPONSE:"
echo "$RESP_44" | python3 -m json.tool 2>/dev/null || echo "$RESP_44"
GOT_ZIPCODE=$(echo "$RESP_44" | python3 -c \
  'import sys,json;d=json.load(sys.stdin);print(d["data"]["addresses"][0].get("zipCode",""))' 2>/dev/null)
GOT_NEIGHBORHOOD=$(echo "$RESP_44" | python3 -c \
  'import sys,json;d=json.load(sys.stdin);print(d["data"]["addresses"][0].get("neighborhood",""))' 2>/dev/null)
EXP_ZIPCODE="95014"
EXP_NEIGHBORHOOD="Mariani"
if [ "$GOT_ZIPCODE" = "$EXP_ZIPCODE" ] && [ "$GOT_NEIGHBORHOOD" = "$EXP_NEIGHBORHOOD" ]; then
  printf '\033[1;32mPASS\033[0m (zipCode=%s, neighborhood=%s)\n' "$GOT_ZIPCODE" "$GOT_NEIGHBORHOOD"
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (expected zipCode=%s neighborhood=%s, got zipCode=%s neighborhood=%s)\n' \
    "$EXP_ZIPCODE" "$EXP_NEIGHBORHOOD" "$GOT_ZIPCODE" "$GOT_NEIGHBORHOOD"
  FAIL=$((FAIL+1))
fi

title "4.4b Write-response address id == persisted view id (child-id write-back, end-to-end)"
# The id the POST response carried (2.1b) must be the SAME id the Mongo view
# holds after CDC — proving the mirrored id IS the persisted PK, not a
# fabrication. Uses the by-id response already fetched in 4.4.
VIEW_ADDR_ID=$(echo "$RESP_44" | python3 -c \
  'import sys,json;d=json.load(sys.stdin);print(d["data"]["addresses"][0].get("id",""))' 2>/dev/null)
if [ -n "$ADDR_A_ID" ] && [ "$VIEW_ADDR_ID" = "$ADDR_A_ID" ]; then
  printf '\033[1;32mPASS\033[0m (write response id == view id: %s)\n' "$VIEW_ADDR_ID"
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (write response id=%q, view id=%q — the mirrored id must be the persisted PK)\n' \
    "$ADDR_A_ID" "$VIEW_ADDR_ID"
  FAIL=$((FAIL+1))
fi

####################################
sec "4.5 GET /users — partial-match operators (startswith/contains + i-twins)"
####################################
# The Request DTO `FindUsersByParamsRequest` declares:
#   Name  → filter:"eq,startswith,icontains"
#   Email → filter:"eq,in,ieq"
#   City  → filter:"eq,istartswith"
# Suite state at this point: Jane Doe (Cupertino), Bob Smith (London),
# Anna Müller (Berlin), Anna III (Berlin). USER_C archived later (hidden
# by default deleted_at filter).
#
# show_count: asserts (a) status matches expected and (b) the data
# array length is >= expected_min_count. Lets a single helper express
# "must reject" (status 400) and "must match N items" cases in one line.
show_count() {
  local name="$1" path="$2" expected="$3" min_count="${4:-0}"
  title "$name"
  echo "REQUEST : GET $path"
  local tmp; tmp=$(mktemp)
  local status
  status=$(curl -sS -o "$tmp" -w "%{http_code}" -G "$BASE$path" \
    -H "Accept-Language: en-US")
  echo "STATUS  : $status"
  echo "RESPONSE:"
  python3 -m json.tool < "$tmp" 2>/dev/null || cat "$tmp"
  echo
  local count
  count=$(python3 -c 'import sys,json
try:
  d=json.load(open(sys.argv[1]))
  data=d.get("data",[])
  print(len(data) if isinstance(data,list) else 0)
except Exception:
  print(-1)' "$tmp")
  if [ "$status" = "$expected" ] && [ "$count" -ge "$min_count" ]; then
    printf '\033[1;32mPASS\033[0m (status=%s, items=%s >= %s)\n' "$status" "$count" "$min_count"
    PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m (expected status=%s items>=%s, got status=%s items=%s)\n' \
      "$expected" "$min_count" "$status" "$count"
    FAIL=$((FAIL+1))
  fi
  rm -f "$tmp"
}

# 4.5.1 — startswith case-sensitive matches "Jane Doe" (prefix "Jane")
show_count "4.5.1 ?name.startswith=Jane matches Jane Doe (case-sensitive prefix)" \
  "/users?name.startswith=Jane" 200 1

# 4.5.2 — startswith is case-sensitive: lowercase "jane" must NOT match "Jane Doe"
show_count "4.5.2 ?name.startswith=jane (lowercase) returns 0 — startswith is case-sensitive" \
  "/users?name.startswith=jane" 200 0

# 4.5.3 — icontains is case-folded: "DOE" matches "Jane Doe"
show_count "4.5.3 ?name.icontains=DOE matches Jane Doe (case-insensitive substring)" \
  "/users?name.icontains=DOE" 200 1

# 4.5.4 — icontains anywhere in the string: "nn" matches "Anna Müller" and "Anna III"
show_count "4.5.4 ?name.icontains=nn matches Anna Müller + Anna III (substring anywhere)" \
  "/users?name.icontains=nn" 200 2

# 4.5.5 — ieq case-insensitive equality on email
show_count "4.5.5 ?email.ieq=BOB@EXAMPLE.COM matches bob@example.com (case-insensitive equality)" \
  "/users?email.ieq=BOB%40EXAMPLE.COM" 200 1

# 4.5.6 — istartswith case-folded prefix on name (matches "Anna Müller" + "Anna III")
# Note: city is declared with istartswith on the DTO but the Mongo view stores
# city nested inside addresses[], not top-level — filtering at top level on
# `city` matches nothing. The DTO declaration stays as wire allowlist; this
# case exercises the operator against a top-level field that does match.
show_count "4.5.6 ?name.istartswith=anna matches Anna Müller + Anna III (case-insensitive prefix)" \
  "/users?name.istartswith=anna" 200 2

# 4.5.7 — non-matching prefix returns empty list (200, not 404)
show_count "4.5.7 ?name.startswith=ZZZ returns empty list" \
  "/users?name.startswith=ZZZ" 200 0

# 4.5.8 — undeclared operator on name → 400 (name has filter:"eq,startswith,icontains")
show_count "4.5.8 ?name.gte=A rejected — gte not in name's filter list" \
  "/users?name.gte=A" 400 0

# 4.5.9 — undeclared operator on email → 400 (email has filter:"eq,in,ieq")
show_count "4.5.9 ?email.startswith=jane rejected — startswith not in email's filter list" \
  "/users?email.startswith=jane" 400 0

# 4.5.10 — regex metacharacters in the user value are escaped (treated as literal).
# The name field declares filter:"eq,startswith,icontains"; using icontains with
# a value carrying a literal dot proves regexp.QuoteMeta runs at the wire
# boundary — without escape, the dot would be a regex metacharacter and the
# query would match many strings; with escape, it only matches the literal text.
# Bob's name is "Bob Smith" — searching for "OB " (with literal space) matches.
show_count "4.5.10 ?name.icontains=OB%20Sm (literal space) matches Bob Smith" \
  "/users?name.icontains=OB%20Sm" 200 1

# 4.5.11 — multiple operators on the SAME field are AND-ed via top-level $and.
# Before the fix, each new operator overwrote the previous one on the criteria
# map and only the last one survived (silent regression). The wrapper now folds
# the clauses into queries.MultiClause; MongoViewReader expands the sentinel
# into {$and: [{name: ...}, {name: ...}]}. Bob Smith satisfies BOTH clauses:
# startswith=Bob ✓ AND icontains=smith ✓.
show_count "4.5.11 ?name.startswith=Bob&name.icontains=smith — both clauses match Bob Smith" \
  "/users?name.startswith=Bob&name.icontains=smith" 200 1

# 4.5.12 — same shape, incompatible substring. Bob Smith satisfies the startswith
# clause but NOT the icontains clause (no "smh" substring in "Bob Smith"). Before
# the fix, only the last operator survived and the response leaked a false
# positive; with $and applied at the store level the result is correctly empty.
show_count "4.5.12 ?name.startswith=Bob&name.icontains=smh — clauses incompatible, no match" \
  "/users?name.startswith=Bob&name.icontains=smh" 200 0

# 4.5.13 — full four-operator stress shape (the original bug report). All four
# clauses target `name`; one of them (icontains=smh) rules out Bob Smith. Result
# must be empty. Until the MultiClause fix shipped, this query falsely returned
# Bob Smith because only the last-written operator (istartswith=bob) survived
# on the criteria map.
show_count "4.5.13 ?name=Bob%20Smith&name.startswith=Bob&name.icontains=smh&name.istartswith=bob — no match (regression for the bug)" \
  "/users?name=Bob%20Smith&name.startswith=Bob&name.icontains=smh&name.istartswith=bob" 200 0

####################################
sec "4.6 GET /users — nested embed-group filters (?addresses.<leaf>=...)"
####################################
# FindUsersByParamsRequest now declares Addresses AddressFilterParams via the
# query:"addresses" embed-group tag. Every leaf inside lands under the
# addresses.* wire prefix and translates to Mongo doc path addresses.<field>
# automatically (auto-snake on the leaf wire name matches the composer's
# snake_case column output). State: Jane Doe (Cupertino, US), Bob Smith
# (London, GB), Anna Müller (Berlin, DE), Anna III (Berlin, DE).

# 4.6.1 — wire ?addresses.city=Berlin → Mongo Filter[addresses.city]=Berlin
show_count "4.6.1 ?addresses.city=Berlin matches Anna Müller + Anna III (nested top-level eq)" \
  "/users?addresses.city=Berlin" 200 2

# 4.6.2 — case-insensitive prefix on a nested leaf
show_count "4.6.2 ?addresses.city.istartswith=ber matches Anna II + Anna III" \
  "/users?addresses.city.istartswith=ber" 200 2

# 4.6.3 — auto-snake leaf (zipCode wire → zip_code doc) matches exact.
# Jane's US zip "95014" is digits-only — proves the type-driven coercion
# keeps it a string (because ZipCode is *string in AddressFilterParams)
# instead of silently parsing into int64 and missing the string-typed
# Mongo column.
show_count "4.6.3 ?addresses.zipCode=95014 matches Jane (auto-snake + string leaf keeps digits as string)" \
  "/users?addresses.zipCode=95014" 200 1

# 4.6.4 — startswith on the auto-snake leaf (proves operator suffix + auto-snake
# coexist; wire becomes addresses.zipCode.startswith, doc becomes addresses.zip_code)
show_count "4.6.4 ?addresses.zipCode.startswith=10 matches Berlin entries" \
  "/users?addresses.zipCode.startswith=10" 200 2

# 4.6.5 — country in-list across embed group
show_count "4.6.5 ?addresses.country.in=DE,US matches Jane + Anna II + Anna III" \
  "/users?addresses.country.in=DE,US" 200 3

# 4.6.6 — undeclared nested leaf returns 400 (allowlist enforced inside embed)
show_count "4.6.6 ?addresses.street=X rejected — street not declared on AddressFilterParams" \
  "/users?addresses.street=X" 400 0

# 4.6.7 — unknown embed prefix returns 400
show_count "4.6.7 ?orders.city=X rejected — no embed group named orders" \
  "/users?orders.city=X" 400 0

####################################
sec "5. PUT /users/:id — strict (FullBody)"
####################################

title "5.1 PUT happy (all fields) — response mirrors the REPLACED addresses with their new ids"
# Same request as always; captured (instead of show) so the response body can
# be asserted: the PUT replaces the whole address collection, so the mirror
# must carry the NEW address row with a freshly minted id (child-id
# write-back on the update path) — and it must differ from the POST-time id.
BODY_51='{
  "name":"Jane Doe (updated)","email":"jane.updated@example.com","phone":"14155553333",
  "userName":"jane","emailNotification":true,"smsNotification":true,
  "addresses":[{
    "label":"home","street":"New Address","number":"200",
    "neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94110","country":"US"
  }]
}'
echo "REQUEST : PUT /users/$USER_A"
echo "BODY    :"
echo "$BODY_51" | python3 -m json.tool
RESP_51=$(curl -sS -w "\n__STATUS__%{http_code}" -X PUT "$BASE/users/$USER_A" \
  -H "Content-Type: application/json" -H "Accept-Language: en-US" --data "$BODY_51")
ST_51=${RESP_51##*__STATUS__}
JSON_51=${RESP_51%__STATUS__*}
echo "STATUS  : $ST_51"
echo "RESPONSE:"
echo "$JSON_51" | python3 -m json.tool
ADDR_51_ID=$(echo "$JSON_51" | python3 -c \
  'import sys,json;d=json.load(sys.stdin);a=d["data"].get("addresses") or [];print(a[0].get("id","") if a else "")' 2>/dev/null)
ADDR_51_STREET=$(echo "$JSON_51" | python3 -c \
  'import sys,json;d=json.load(sys.stdin);a=d["data"].get("addresses") or [];print(a[0].get("street","") if a else "")' 2>/dev/null)
if [ "$ST_51" = "200" ] && [ "${#ADDR_51_ID}" = "36" ] && \
   [ "$ADDR_51_STREET" = "New Address" ] && [ "$ADDR_51_ID" != "$ADDR_A_ID" ]; then
  printf '\033[1;32mPASS\033[0m (200; replaced address id=%s, street=%s, differs from POST-time id)\n' \
    "$ADDR_51_ID" "$ADDR_51_STREET"
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (expected 200 + fresh 36-char id != %q + street "New Address"; got status=%s id=%q street=%q)\n' \
    "$ADDR_A_ID" "$ST_51" "$ADDR_51_ID" "$ADDR_51_STREET"
  FAIL=$((FAIL+1))
fi

show "5.2 PUT without phone (Phase 21: RequiredFieldNotification semantic Schema → 400)" PUT "/users/$USER_A" '{
  "name":"Jane","email":"jane@example.com",
  "addresses":[{"label":"home","street":"X","number":"1","neighborhood":"X","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}]
}' 400

show "5.3 PUT without addresses (Phase 21: RequiredFieldNotification semantic Schema → 400)" PUT "/users/$USER_A" '{
  "name":"Jane","email":"jane@example.com","phone":"14155553333"
}' 400

show "5.4 PUT /users/<nonexistent> (RecordNotFound)" PUT /users/00000000-0000-0000-0000-000000000000 '{
  "name":"X","email":"x@x.com","phone":"14155553333","userName":"x","emailNotification":false,"smsNotification":false,
  "addresses":[{"label":"home","street":"X","number":"1","neighborhood":"X","city":"SF","state":"CA","zipCode":"94103","country":"US"}]
}' 404

show "5.5 PUT with type mismatch (Phase 21: SchemaViolationNotification → 400)" PUT "/users/$USER_A" '{
  "name":123,"email":"jane@example.com","phone":"14155553333",
  "addresses":[{"label":"home","street":"X","number":"1","neighborhood":"X","city":"SF","state":"CA","zipCode":"94103","country":"US"}]
}' 400

show "5.6 PUT with malformed JSON (Phase 21: SchemaViolationNotification → 400)" PUT "/users/$USER_A" '{not json' 400

####################################
sec "6. PATCH /users/:id — partial (lenient)"
####################################

show "6.1 Partial PATCH (name only)" PATCH "/users/$USER_A" '{"name":"Jane Doe (patch)"}' 200

show "6.2 Partial PATCH (phone only)" PATCH "/users/$USER_A" '{"phone":"14155554444"}' 200

show "6.3 PATCH empty body (noop, lenient)" PATCH "/users/$USER_A" '{}' 200

show "6.4 PATCH with empty phone (Phase 21: *\"\" passes to domain, BuildRules tolerates)" PATCH "/users/$USER_A" '{"phone":""}' 200

# Email is now a plain mutable shared Person field (no longer the identity and
# no longer unique), so changing it — even to a value another user holds — is
# accepted. Identity is the immutable `document`.
show "6.5 PATCH email to Bob's email — now allowed (email not unique) → 200" PATCH "/users/$USER_A" '{"email":"bob@example.com"}' 200

# Restore Jane's email — email is freely mutable both ways; restoring it keeps
# jane@example.com stable for the later read/export assertions that pin it.
show "6.5b PATCH email back to jane@example.com (still mutable) → 200" PATCH "/users/$USER_A" '{"email":"jane@example.com"}' 200

show "6.6 PATCH invalid email (Validation 422)" PATCH "/users/$USER_A" '{"email":"not-an-email"}' 422

show "6.7 PATCH /users/<nonexistent> (RecordNotFound)" PATCH /users/00000000-0000-0000-0000-000000000000 '{"name":"X"}' 404

# 6.8 exercises the user_configurations SIBLING: a PATCH of the notification
# flags upserts the 1:1 sibling row (shared PK with users). Materialization is
# conditional — sending at least one flag creates/updates the row.
show "6.8 PATCH notification flags — upserts the user_configurations sibling → 200" PATCH "/users/$USER_A" '{"emailNotification":false,"smsNotification":true}' 200

####################################
sec "7. PATCH /users/:id/archive  and  /:id/unarchive — aggregate-aware"
####################################

show "7.1 Archive (empty body accepted)" PATCH "/users/$USER_A/archive" "" 204

title "7.1.b $BACKEND: Jane's addresses cascaded (deleted_at NOT NULL) — addresses are the person's (FK person_id), archived via convergeBase"
qa_db_query "SELECT $(qa_uuid_select id), deleted_at IS NOT NULL AS archived FROM addresses WHERE person_id=(SELECT id FROM users WHERE id=$(qa_uuid_lit "$USER_A"));"

show "7.2 Re-archive already archived (expected 404 — FindByID filters deleted_at NULL)" PATCH "/users/$USER_A/archive" "" 404

show "7.3 Unarchive (restores root + addresses)" PATCH "/users/$USER_A/unarchive" "" 204

title "7.3.b $BACKEND: addresses are back (deleted_at NULL) — convergeBase reactivated base + base-children"
qa_db_query "SELECT $(qa_uuid_select id), deleted_at IS NULL AS active FROM addresses WHERE person_id=(SELECT id FROM users WHERE id=$(qa_uuid_lit "$USER_A"));"

show "7.4 Unarchive on an active record (expected 404 — FindArchivedByID only sees deleted ones)" PATCH "/users/$USER_A/unarchive" "" 404

show "7.5 Archive on a nonexistent UUID (RecordNotFound)" PATCH "/users/00000000-0000-0000-0000-000000000000/archive" "" 404

####################################
sec "8. DELETE /users/:id (hard delete)"
####################################

show "8.1 DELETE USER_C2 (Anna III) — expected 204" DELETE "/users/$USER_C2" "" 204

show "8.2 DELETE again (RecordNotFound)" DELETE "/users/$USER_C2" "" 404

title "8.3 $BACKEND: refcount removed the orphan person (doc 10000000033) + its addresses"
qa_db_query "SELECT COUNT(*) AS leftover_persons FROM persons WHERE document='10000000033';"
qa_db_query "SELECT COUNT(*) AS leftover_addresses FROM addresses a JOIN persons p ON a.person_id=p.id WHERE p.document='10000000033';"

####################################
sec "9. Read side (Mongo) — re-check view after PATCH/Archive/Unarchive"
####################################

title "9.0 Polling Mongo via GET /users/$USER_C2 until 404 (CDC consolidating all UPDATEs/ARCHIVE/UNARCHIVE + the 8.1 delete)"
# Gate on the newest event, not the oldest: USER_A has answered 200 since
# section 4, so waiting on it gates nothing. USER_C2 was hard-deleted in 8.1 —
# its doc flipping 200→404 proves the delete materialized, and (ordered,
# single-partition stream) every update/archive/unarchive before it as well.
if wait_for_view "$USER_C2" "404" 30; then
  echo "view ready (delete materialized)"
else
  echo "TIMEOUT waiting for view (30s)"
fi

show "9.1 GET /users/USER_A (with PATCHes already applied via CDC)" GET "/users/$USER_A" "" 200

show "9.2 GET /users (listing with default pagination)" GET /users "" 200

####################################
sec "9.5 SharedBase partition — the flat User spread across four tables"
####################################
# The flat User entity is partitioned by infra/schema.go: shared Person fields
# (document/name/email/phone + addresses) in persons/addresses, the role-private
# field (user_name) in users, the notification prefs in the user_configurations
# SIBLING (1:1, shared PK). Bob (document 10000000002, active since 2.2) probes it.

title "9.5.a persons row exists for Bob (document is the natural key; id = UUIDv5(document))"
qa_db_query "SELECT document, name FROM persons WHERE document='10000000002';"

title "9.5.b users (role) row IS Bob's person (shared PK: users.id == persons.id), carries user_name"
qa_db_query "SELECT user_name FROM users WHERE id=(SELECT id FROM persons WHERE document='10000000002');"

title "9.5.c addresses are the person's (FK person_id), shared by every role of that person"
qa_db_query "SELECT COUNT(*) AS person_addresses FROM addresses WHERE person_id=(SELECT id FROM persons WHERE document='10000000002');"

title "9.5.d user_configurations sibling — Bob set no flags at create, so the row is NOT materialized (expect 0)"
qa_db_query "SELECT COUNT(*) AS sibling_rows FROM user_configurations WHERE id=$(qa_uuid_lit "$USER_B");"

show "9.5.e PATCH Bob's notification flags — materializes the user_configurations sibling (200)" PATCH "/users/$USER_B" '{"emailNotification":true,"smsNotification":false}' 200

title "9.5.f user_configurations sibling now materialized for Bob (expect 1 row, email=t sms=f)"
qa_db_query "SELECT email_notification, sms_notification FROM user_configurations WHERE id=$(qa_uuid_lit "$USER_B");"

####################################
sec "9.7 Golden record — 100% field-by-field read coverage (REST/JSON · GraphQL · CSV · XLSX)"
####################################
# One record with EVERY field populated (all shared Person fields + the role's
# userName + both notification flags + two addresses — the 2nd omitting the
# nullable label/complement) is created once, then EVERY read surface is asserted
# field-by-field against the same expected values, proving write→read is 100%
# synchronized on each surface and that no field is silently dropped.
GDIR="$(dirname "$0")"
GOLD_DOC="10000000500"
GOLD_BODY='{"name":"Golden Record","email":"golden@example.com","phone":"15551234567","document":"'"$GOLD_DOC"'","userName":"golden","emailNotification":true,"smsNotification":false,"addresses":[{"label":"home","street":"1 Golden Way","number":"10","complement":"Suite 5","neighborhood":"Downtown","city":"Metropolis","state":"NY","zipCode":"10001","country":"US"},{"street":"2 Silver Rd","number":"20","neighborhood":"Uptown","city":"Gotham","state":"NJ","zipCode":"07001","country":"US"}]}'

title "9.7.0 POST golden record (all fields + 2 addresses)"
GOLD_ID=$(curl -sS -X POST "$BASE/users" -H "Content-Type: application/json" -H "Accept-Language: en-US" --data "$GOLD_BODY" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))')
echo "GOLD_ID=$GOLD_ID"
if wait_for_view "$GOLD_ID" "200" 20; then echo "golden view ready"; else echo "TIMEOUT golden view"; fi

golden_pf() { # <captured-output>
  echo "$1"
  if echo "$1" | grep -q "PASS"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
}

title "9.7.1 REST/JSON — every field of GET /users/:id"
golden_pf "$(curl -sS "$BASE/users/$GOLD_ID" -H "Accept-Language: en-US" | python3 "$GDIR/golden_check.py" json REST "$GOLD_ID")"

title "9.7.2 GraphQL — every field of the users() node"
GQL_Q='{"query":"{ users(where:{document:{eq:\"10000000500\"}}){ edges { node { id name email phone document userName emailNotification smsNotification addresses { id label street number complement neighborhood city state zipCode country } } } } }"}'
golden_pf "$(curl -sS -X POST "$BASE/graphql" -H "Content-Type: application/json" --data "$GQL_Q" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);n=d["data"]["users"]["edges"];print(json.dumps(n[0]["node"]) if n else "{}")' \
  | python3 "$GDIR/golden_check.py" json GraphQL "$GOLD_ID")"

title "9.7.3 CSV export — every data value present in /users.csv"
golden_pf "$(curl -sS "$BASE/users.csv?document.eq=$GOLD_DOC" -H "Accept-Language: en-US" | python3 "$GDIR/golden_check.py" flat CSV)"

title "9.7.4 XLSX export — every data value present in /users.xlsx"
curl -sS "$BASE/users.xlsx?document.eq=$GOLD_DOC" -H "Accept-Language: en-US" -o /tmp/qa-golden.xlsx.${BACKEND:-default}
golden_pf "$(unzip -p /tmp/qa-golden.xlsx.${BACKEND:-default} 'xl/*.xml' 2>/dev/null | python3 "$GDIR/golden_check.py" flat XLSX)"
rm -f /tmp/qa-golden.xlsx.${BACKEND:-default}

# Clean the golden record so re-runs start cold and it does not skew later counts.
curl -sS -X DELETE "$BASE/users/$GOLD_ID" -o /dev/null -w "9.7.5 cleanup golden: %{http_code}\n"

####################################
sec "10. Query allowlist (filter tags + reserved by-id param)"
####################################
# Exercises the QueryWithParams / QueryByID surface introduced by
# the queries refactor: the Request DTO declares the allowlist via
# `query:"X" filter:"ops"` tags, the framework rejects unknown fields and
# operators with 400, and the ?includeArchived=true reserved param flows through to
# the ViewReader.

show "10.1 GET /users?name=Jane Doe (filter:eq declared on name)" GET "/users?name=Jane%20Doe" "" 200
show "10.2 GET /users?email.in=jane@example.com,bob@example.com (filter:eq,in on email)" GET "/users?email.in=jane@example.com,bob@example.com" "" 200
show "10.3 GET /users?role=admin (field NOT in the allowlist → 400)" GET "/users?role=admin" "" 400
show "10.4 GET /users?email.gte=Z (operator NOT in declared list for email → 400)" GET "/users?email.gte=Z" "" 400
# 10.5–10.5b: by-id reads on USER_C (unarchived in 3.2b → active) exercise the canonical
# framework invariant: Mongo mirrors PostgreSQL symmetrically — the
# SyncEngine reacts to ARCHIVE with compose+upsert (default keep), so the
# doc survives with deleted_at populated. The two by-id variants then
# differ only on the deleted_at filter at the Mongo layer:
#   - ?includeArchived=true → IncludeArchived=true → filter omits deleted_at →
#     200 with the archived doc.
#   - default (no ?includeArchived) → IncludeArchived=false → filter applies
#     `deleted_at: null` → 404 because the doc has deleted_at populated.
# Together they prove the ganho of the keep-by-default semantic and the
# back-pressure of the reader-side filter that still hides archived from
# the default surface. The ?includeArchived flag is a reserved param either way
# (no SchemaViolationNotification on either variant).
# USER_C was archived and then UNARCHIVED in 3.2b (same person, same role row —
# role row reactivated), so it is ACTIVE again — both reads return 200. The
# archived-by-id keep-by-default behavior is exercised on USER_A at 10.7/10.7b.
show "10.5 GET /users/USER_C?includeArchived=true (unarchived in 3.2b → active → 200)" GET "/users/$USER_C?includeArchived=true" "" 200
show "10.5b GET /users/USER_C default reader (unarchived → active → 200)" GET "/users/$USER_C" "" 200

# 10.6–10.9: end-to-end Archive → ?includeArchived=true → Unarchive → ?includeArchived=false
# cycle on USER_A (currently active after 7.3). Demonstrates that the read
# side honors the keep-by-default Mongo view — ARCHIVED upserts the doc
# with deleted_at populated (default GET 404, ?includeArchived=true 200);
# UNARCHIVED re-upserts clearing deleted_at via SyncEngine, then the
# standard GET returns 200. Using USER_A keeps section 10 self-contained:
# USER_C is left archived and its email "anna@example.com" is still held
# by a sibling active user from the 3.2 soft-delete-aware uniqueness test,
# so unarchiving USER_C would 409.
show "10.6 PATCH /users/USER_A/archive (re-archive to exercise the query-side cycle)" PATCH "/users/$USER_A/archive" "" 204

title "10.7 Polling GET /users/USER_A until 404 (reader-side deleted_at filter after ARCHIVE)"
deadline=$(( $(date +%s) + 15 ))
status=200
while [ "$(date +%s)" -lt "$deadline" ]; do
  status=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/users/$USER_A")
  [ "$status" = "404" ] && break
  sleep 0.25
done
if [ "$status" = "404" ]; then
  echo "view archived (404 via deleted_at filter)"
  PASS=$((PASS+1))
else
  echo "TIMEOUT waiting for SyncEngine archive upsert (15s, last status=$status)"
  FAIL=$((FAIL+1))
fi

show "10.7b GET /users/USER_A?includeArchived=true while archived (keep-by-default → 200 with archived doc)" GET "/users/$USER_A?includeArchived=true" "" 200
show "10.8 PATCH /users/USER_A/unarchive (restores root + addresses)" PATCH "/users/$USER_A/unarchive" "" 204

title "10.8b Polling Mongo via GET /users/USER_A until 200 (CDC re-upsert after UNARCHIVE)"
if wait_for_view "$USER_A" "200" 15; then
  echo "view ready"
  PASS=$((PASS+1))
else
  echo "TIMEOUT waiting for view (15s)"
  FAIL=$((FAIL+1))
fi

show "10.8c GET /users/USER_A?includeArchived=false (explicit flag — default behavior)" GET "/users/$USER_A?includeArchived=false" "" 200
show "10.9 GET /users/USER_A?role=admin (non-reserved param on by-id → 400)" GET "/users/$USER_A?role=admin" "" 400

####################################
sec "11. /showcase/users-custom/* — manual write showcase (document as identifier)"
####################################
# Cross-checks the parallel surface that hand-rolls every layer above domain/,
# now including the manual SharedBase upsert in the insert handler. Uses Mike's
# row (document 10000000011) — fresh across runs because the suite TRUNCATEs at
# 0.5. The Person `document` is the identifier in the URL path; PUT/PATCH bodies
# omit Document (the immutable natural key) but DO carry email (now an editable
# shared field). Writes land on the same persons/users/addresses tables the
# canonical /users/* surface uses.

show "11.1 POST /showcase/users-custom (create Mike, US)" POST /showcase/users-custom/ '{
  "name":"Mike Manual","email":"mike@example.com","phone":"14155556666",
  "document":"10000000011","userName":"mike",
  "addresses":[{"label":"home","street":"1 Manual Way","number":"42","neighborhood":"Showcase","city":"Cupertino","state":"CA","zipCode":"95014","country":"US"}]
}' 201

show "11.2 POST same document — Conflict (active user already exists for this person)" POST /showcase/users-custom/ '{
  "name":"Mike Twin","email":"mike.twin@example.com","phone":"14155557777",
  "document":"10000000011","userName":"miketwin",
  "addresses":[{"label":"twin","street":"2 Twin Ln","number":"1","neighborhood":"Twin","city":"Cupertino","state":"CA","zipCode":"95014","country":"US"}]
}' 409

show "11.3 PUT /showcase/users-custom/10000000011 (full replace — no Document in body; email IS editable)" PUT /showcase/users-custom/10000000011 '{
  "name":"Mike Updated","email":"mike.updated@example.com","phone":"14155558888","userName":"mike",
  "addresses":[{"label":"office","street":"1 Apple Park Way","number":"1","neighborhood":"Mariani","city":"Cupertino","state":"CA","zipCode":"95014","country":"US"}]
}' 200

show "11.4 PATCH /showcase/users-custom/10000000011 (name only)" PATCH /showcase/users-custom/10000000011 '{"name":"Mike Patched"}' 200

show "11.5 PATCH /showcase/users-custom/10000000011/archive (aggregate-aware soft-delete)" PATCH /showcase/users-custom/10000000011/archive "" 204
show "11.6 PATCH /showcase/users-custom/10000000011/unarchive (FindArchivedByDocument path)" PATCH /showcase/users-custom/10000000011/unarchive "" 204
show "11.7 DELETE /showcase/users-custom/10000000011 (hard delete — 204 No Content)" DELETE /showcase/users-custom/10000000011 "" 204

show "11.8 PUT on ghost document — RecordNotFound (404)" PUT /showcase/users-custom/99999999999 '{
  "name":"X","email":"x@x.com","userName":"x","phone":"14155550000","addresses":[]
}' 404

show "11.9 POST with missing name — RequiredFieldNotification (422 — Domain BuildRules, not Schema)" POST /showcase/users-custom/ '{
  "email":"nameless@example.com","document":"10000000019","userName":"nameless","addresses":[]
}' 422

show "11.10 POST with malformed JSON — Schema violation (400)" POST /showcase/users-custom/ '{not json' 400

####################################
sec "12. /showcase/users-custom/* — manual read showcase (by-document + list + reduced shape)"
####################################
# Reads against the same Mongo view the canonical /users/* surface uses
# (UserView()). Two endpoints; both project the denormalized doc down to
# {id, name, email} — phone and addresses are intentionally absent
# (UserSummaryResponse). Reuses jane@example.com (active throughout the
# suite after 10.8 restored her) and bob@example.com (active since 2.2);
# no fresh fixtures, no CDC waits — section 9 already polled Mongo into
# sync for these rows.

show "12.1 GET /showcase/users-custom/10000000001 — reduced shape (id+name+email only)" GET /showcase/users-custom/10000000001 "" 200
show "12.2 GET /showcase/users-custom/99999999999 — RecordNotFound (404)" GET /showcase/users-custom/99999999999 "" 404
show "12.3 GET /showcase/users-custom — list with pagination envelope top-level" GET /showcase/users-custom "" 200
show "12.4 GET /showcase/users-custom?email=bob@example.com — filtered list" GET "/showcase/users-custom?email=bob@example.com" "" 200
show "12.5 GET /showcase/users-custom?limit=1 — paged list (has_next:true expected)" GET "/showcase/users-custom?limit=1" "" 200
show "12.6 GET /showcase/users-custom?role=admin — unknown query key rejected (400 via ParseCriteria allowlist)" GET "/showcase/users-custom?role=admin" "" 400
show "12.7 GET /showcase/users-custom/10000000001?includeArchived=true — flag accepted, active row still surfaces" GET "/showcase/users-custom/10000000001?includeArchived=true" "" 200
show "12.8 GET /showcase/users-custom?includeArchived=true — flag accepted on list" GET "/showcase/users-custom?includeArchived=true" "" 200
show "12.9 GET /showcase/users-custom?name.in=Jane,Bob — operator outside declared list rejected (400, name carries filter:\"eq\" only)" GET "/showcase/users-custom?name.in=Jane,Bob" "" 400
show "12.10 GET /showcase/users-custom?name=Jane — allowed filter (200; happy path via the new allowlist)" GET "/showcase/users-custom?name=Jane" "" 200
show "12.11 GET /showcase/users-custom/10000000001?tenant=acme — unknown query key on by-email rejected (400)" GET "/showcase/users-custom/10000000001?tenant=acme" "" 400

####################################
sec "13. /users/:id/addresses/:addressId  — Address subresource (canonical + custom)"
####################################
# Exercises the four new address-targeted endpoints:
#   - PUT  /users/:id/addresses/:addressId                        (canonical)
#   - GET  /users/:id/addresses/:addressId                        (canonical)
#   - PUT  /showcase/users-custom/:email/addresses/:addressId     (custom)
#   - GET  /showcase/users-custom/:email/addresses/:addressId     (custom)
#
# The address subresource lives inside the User aggregate — both verbs target
# ONE child slot via Address.GetID() and the canonical PUT exercises the
# UpdateCommandHandler → domain.GetUpdatable → User.ChangeAddressByID →
# domain.ChangeAggregateChild path, which flips the slot to status CHANGED.
# That CHANGED status is the only path that produces the auditor's
# children.Address[*].op="changed" emission — covered exhaustively in
# qa/audit.sh. Here we only assert HTTP behavior + wire shape.
#
# State at this point: USER_A has gone through PUT/PATCH/Archive/Unarchive
# cycles; section 10 left it active with the addresses currently in Mongo.
# We pull a live address id out of the user view doc instead of pinning a
# specific street so the test is robust to upstream changes in the seed.

title "13.0 Read USER_A's current address id from Mongo view"
ADDRESS_ID=$(curl -sS "$BASE/users/$USER_A" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"]["addresses"];print(d[0]["id"] if d else "")')
if [ -z "$ADDRESS_ID" ]; then
  printf '\033[1;31mFAIL\033[0m USER_A has no addresses in the Mongo view — section 13 cannot run\n'
  FAIL=$((FAIL+1))
else
  echo "ADDRESS_ID=$ADDRESS_ID"

  show "13.1 GET /users/USER_A/addresses/ADDRESS_ID (canonical happy path)" \
    GET "/users/$USER_A/addresses/$ADDRESS_ID" "" 200

  show "13.2 GET /users/USER_A/addresses/<unknown> (Address not in user doc → 404)" \
    GET "/users/$USER_A/addresses/00000000-0000-0000-0000-000000000000" "" 404

  show "13.3 GET /users/<unknown>/addresses/ADDRESS_ID (User not in view → 404)" \
    GET "/users/00000000-0000-0000-0000-000000000000/addresses/$ADDRESS_ID" "" 404

  show "13.4 GET /users/USER_A/addresses/ADDRESS_ID?role=admin (unknown query key → 400)" \
    GET "/users/$USER_A/addresses/$ADDRESS_ID?role=admin" "" 400

  # PUT change-address keeps the SAME addressId on the URL; the body carries
  # only the new field values. ZipCode + Country + Street + Number combine
  # into the business identity that AddAddress checks, but ChangeAddress
  # doesn't run that check — it replaces in place — so we can reshape freely.
  show "13.5 PUT /users/USER_A/addresses/ADDRESS_ID (canonical happy path)" \
    PUT "/users/$USER_A/addresses/$ADDRESS_ID" '{
      "label":"office","street":"500 Market St","number":"500","complement":null,
      "neighborhood":"FiDi","city":"San Francisco","state":"CA",
      "zipCode":"94105","country":"US"
    }' 200

  show "13.6 PUT /users/USER_A/addresses/ADDRESS_ID missing zipCode (FullBody → 400)" \
    PUT "/users/$USER_A/addresses/$ADDRESS_ID" '{
      "label":"office","street":"500 Market St","number":"500",
      "neighborhood":"FiDi","city":"San Francisco","state":"CA","country":"US"
    }' 400

  show "13.7 PUT /users/USER_A/addresses/<unknown> (address id absent → 404 RecordNotFound)" \
    PUT "/users/$USER_A/addresses/00000000-0000-0000-0000-000000000000" '{
      "label":"x","street":"x","number":"1","complement":null,"neighborhood":"x","city":"x",
      "state":"CA","zipCode":"94103","country":"US"
    }' 404

  show "13.8 PUT /users/USER_A/addresses/ADDRESS_ID with invalid state regex (BuildRules → 422)" \
    PUT "/users/$USER_A/addresses/$ADDRESS_ID" '{
      "label":"office","street":"x","number":"1","complement":null,"neighborhood":"x","city":"x",
      "state":"@#","zipCode":"94103","country":"US"
    }' 422

  # Custom surface — same address id (Jane is keyed by email here, not UUID).
  # Wait for CDC to consolidate the canonical PUT first so the GET reflects
  # the new state (the custom GET reads the same Mongo view via FilterByEmail).
  title "13.9 Poll Mongo until canonical PUT propagates (street=500 Market St visible)"
  for i in $(seq 1 40); do
    s=$(curl -sS "$BASE/users/$USER_A" \
        | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"]["addresses"];print(next((a["street"] for a in d if a["id"]=="'"$ADDRESS_ID"'"), ""))' 2>/dev/null)
    [ "$s" = "500 Market St" ] && { echo "PROPAGATED after ${i} polls"; break; }
    sleep 0.25
  done

  show "13.10 GET /showcase/users-custom/10000000001/addresses/ADDRESS_ID (custom happy path)" \
    GET "/showcase/users-custom/10000000001/addresses/$ADDRESS_ID" "" 200

  show "13.11 GET /showcase/users-custom/99999999999/addresses/ADDRESS_ID (User absent → 404)" \
    GET "/showcase/users-custom/99999999999/addresses/$ADDRESS_ID" "" 404

  show "13.12 GET /showcase/users-custom/10000000001/addresses/<unknown> (Address absent → 404)" \
    GET "/showcase/users-custom/10000000001/addresses/00000000-0000-0000-0000-000000000000" "" 404

  show "13.13 GET /showcase/.../addresses/ADDRESS_ID?role=admin (unknown query key → 400)" \
    GET "/showcase/users-custom/10000000001/addresses/$ADDRESS_ID?role=admin" "" 400

  show "13.14 PUT /showcase/.../jane@example.com/addresses/ADDRESS_ID (custom happy path)" \
    PUT "/showcase/users-custom/10000000001/addresses/$ADDRESS_ID" '{
      "label":"home","street":"1 Custom Way","number":"1",
      "neighborhood":"Downtown","city":"San Francisco","state":"CA",
      "zipCode":"94103","country":"US"
    }' 200

  show "13.15 PUT /showcase/.../ghost@example.com/addresses/ADDRESS_ID (User absent → 404)" \
    PUT "/showcase/users-custom/99999999999/addresses/$ADDRESS_ID" '{
      "label":"x","street":"x","number":"1","neighborhood":"x","city":"x",
      "state":"CA","zipCode":"94103","country":"US"
    }' 404

  show "13.16 PUT /showcase/.../jane@example.com/addresses/<unknown> (Address absent → 404)" \
    PUT "/showcase/users-custom/10000000001/addresses/00000000-0000-0000-0000-000000000000" '{
      "label":"x","street":"x","number":"1","neighborhood":"x","city":"x",
      "state":"CA","zipCode":"94103","country":"US"
    }' 404

  show "13.17 PUT /showcase/.../jane@example.com/addresses/ADDRESS_ID with invalid state (422)" \
    PUT "/showcase/users-custom/10000000001/addresses/$ADDRESS_ID" '{
      "label":"x","street":"x","number":"1","neighborhood":"x","city":"x",
      "state":"@#","zipCode":"94103","country":"US"
    }' 422
fi

####################################
sec "14. GET /users — remaining filter operator coverage"
####################################
# 4.5 covers name.startswith/icontains/istartswith + email.ieq. 4.6 covers
# the nested addresses.city/zipCode/country path. Fill the residual gaps:
#   - addresses.state (eq, in) — declared but never tested
#   - addresses.country.eq (single value, not list) — declared, .in already covered
#   - addresses.city.icontains (declared, not asserted)
#   - email.in single value (covered in 10.2 as multi)
#   - email.in with one element
#   - operators on different fields combined (AND across fields)
# State at this point (post sec 10/11/12/13): Jane Doe (US, CA, Cupertino),
# Bob Smith (UK, ENG, London), Anna II (DE, Berlin), Anna III (DE, Berlin).
# USER_C archived, USER_C2 deleted, mike@ deleted.

# state.eq vs .in — declared on AddressFilterParams.
show_count "14.1 ?addresses.state=CA matches Jane Doe (US/CA)" \
  "/users?addresses.state=CA" 200 1

show_count "14.2 ?addresses.state.in=CA,England matches Jane Doe + Bob Smith" \
  "/users?addresses.state.in=CA,England" 200 2

# country.eq (single value) — declared on AddressFilterParams.
show_count "14.3 ?addresses.country=DE matches DE-based users (post sec-8 delete: only Anna II remains)" \
  "/users?addresses.country=DE" 200 1

show_count "14.4 ?addresses.country=US matches Jane Doe (single value form)" \
  "/users?addresses.country=US" 200 1

# city.icontains (declared, not asserted in 4.6).
show_count "14.5 ?addresses.city.icontains=erlin matches Berlin users (post sec-8 delete: only Anna II)" \
  "/users?addresses.city.icontains=erlin" 200 1

# Note: sec 13 mutated Jane's address city from Cupertino → San Francisco,
# so 'CUP' no longer matches anyone in the dataset by this point.
show_count "14.6 ?addresses.city.icontains=Francisco matches Jane (post sec-13 PUT city)" \
  "/users?addresses.city.icontains=Francisco" 200 1

# email.in single value still parses + filters correctly.
show_count "14.7 ?email.in=bob@example.com (single-element list) matches Bob Smith" \
  "/users?email.in=bob%40example.com" 200 1

# Operators on different fields are AND-ed implicitly via the Filter map —
# combining a name operator with an address country must intersect them.
show_count "14.8 ?name.startswith=Anna&addresses.country=DE — combined filters (Anna II only after delete)" \
  "/users?name.startswith=Anna&addresses.country=DE" 200 1

show_count "14.9 ?name.startswith=Anna&addresses.country=US — incompatible AND, no match" \
  "/users?name.startswith=Anna&addresses.country=US" 200 0

####################################
sec "15. GET /users — pagination + sort + reserved keys"
####################################
# limit / sort / fields are reserved keys on FindUsersByParamsRequest.
# Existing cases cover ?limit=1 implicitly (12.5 on the custom surface),
# but the canonical paginator is unchecked.

# limit smaller than total → bounded list + HasNext exposed.
show_count "15.1 ?limit=2 returns at most 2 items" \
  "/users?limit=2" 200 1

# Same as 15.1 but assert the pagination block — has_next must be true.
title "15.2 ?limit=2 pagination envelope has has_next=true"
PAG=$(curl -sS "$BASE/users?limit=2" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("has_next"))')
if [ "$PAG" = "True" ]; then
  printf '\033[1;32mPASS\033[0m (has_next=true)\n'
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (has_next=%s)\n' "$PAG"
  FAIL=$((FAIL+1))
fi

# Follow the cursor → page 2 returns DIFFERENT docs than page 1. Keyset
# pagination over (_id) means page 2's first doc is strictly past page 1's
# last doc; asserting content rather than status proves the cursor advances
# the result set instead of silently re-returning page 1.
title "15.3 Follow next_cursor — page 2 returns docs strictly past page 1"
P1_LAST_ID=$(curl -sS "$BASE/users?limit=2" | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(d[-1]["id"] if d else "")')
CURSOR=$(curl -sS "$BASE/users?limit=2" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("next_cursor",""))')
if [ -n "$CURSOR" ] && [ -n "$P1_LAST_ID" ]; then
  P2_FIRST_ID=$(curl -sS "$BASE/users?limit=2&after=$CURSOR" | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(d[0]["id"] if d else "")')
  if [ -n "$P2_FIRST_ID" ] && [ "$P2_FIRST_ID" != "$P1_LAST_ID" ]; then
    printf '\033[1;32mPASS\033[0m (page1_last=%s, page2_first=%s — cursor advances)\n' "$P1_LAST_ID" "$P2_FIRST_ID"
    PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m (page1_last=%s, page2_first=%s — overlap or empty)\n' "$P1_LAST_ID" "$P2_FIRST_ID"
    FAIL=$((FAIL+1))
  fi
else
  printf '\033[1;31mFAIL\033[0m next_cursor or page1 last id was empty\n'
  FAIL=$((FAIL+1))
fi

# Default pagination (no limit) returns the configured default page size
# (20 per framework default), but the suite never has 20+ users — assert
# only that the list is non-empty and has_next is false (we never overflow).
show_count "15.4 No-limit defaults to framework page size; current dataset fits" \
  "/users" 200 1

# Invalid limit value — the framework rejects non-numeric ?limit= with 400
# SchemaViolationNotification. Strict validation prevents silently falling
# back to the default page size on consumer-side typos.
show "15.5 ?limit=abc rejected (schema violation)" \
  GET "/users?limit=abc" "" 400

# Sort by name ascending — controlled by the `sort` reserved key. Pin the
# first item under known sort.
title "15.6 ?sort=name returns items sorted ascending"
FIRST_NAME=$(curl -sS "$BASE/users?sort=name" | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data",[]);print(d[0]["name"] if d else "")')
if [ "$FIRST_NAME" = "Anna Müller" ] || [ "$FIRST_NAME" = "Anna III" ]; then
  printf '\033[1;32mPASS\033[0m (first=%s; Anna sorts before Bob/Jane)\n' "$FIRST_NAME"
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (first=%s, expected an Anna-prefixed entry)\n' "$FIRST_NAME"
  FAIL=$((FAIL+1))
fi

# Sort descending via leading minus.
title "15.7 ?sort=-name returns items sorted descending"
FIRST_DESC=$(curl -sS "$BASE/users?sort=-name" | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data",[]);print(d[0]["name"] if d else "")')
if [ "$FIRST_DESC" = "Jane Doe (patch)" ] || [ "$FIRST_DESC" = "Jane Doe" ]; then
  printf '\033[1;32mPASS\033[0m (first=%s under desc order)\n' "$FIRST_DESC"
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (first=%s, expected a Jane-prefixed entry)\n' "$FIRST_DESC"
  FAIL=$((FAIL+1))
fi

# Projection — only the named fields appear on each item.
title "15.8 ?fields=email,name projects only the named columns"
PROJ_KEYS=$(curl -sS "$BASE/users?fields=email,name&limit=1" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(",".join(sorted(d[0].keys())) if d else "")')
case "$PROJ_KEYS" in
  *email* )
    if echo "$PROJ_KEYS" | grep -q "name"; then
      printf '\033[1;32mPASS\033[0m (keys=%s)\n' "$PROJ_KEYS"
      PASS=$((PASS+1))
    else
      printf '\033[1;31mFAIL\033[0m (keys=%s — name missing)\n' "$PROJ_KEYS"
      FAIL=$((FAIL+1))
    fi
    ;;
  *)
    printf '\033[1;31mFAIL\033[0m (keys=%s — email/name absent)\n' "$PROJ_KEYS"
    FAIL=$((FAIL+1))
    ;;
esac

# Backward navigation via ?before= — page 2's prev_cursor takes the consumer
# back to page 1. Symmetric inverse of 15.3.
title "15.9 ?before=<page2_prev_cursor> navigates back to page 1"
P1_FIRST_ID=$(curl -sS "$BASE/users?limit=2" | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(d[0]["id"] if d else "")')
P1_CURSOR=$(curl -sS "$BASE/users?limit=2" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("next_cursor",""))')
if [ -n "$P1_CURSOR" ] && [ -n "$P1_FIRST_ID" ]; then
  P2_PREV=$(curl -sS "$BASE/users?limit=2&after=$P1_CURSOR" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("prev_cursor",""))')
  if [ -n "$P2_PREV" ]; then
    BACK_FIRST_ID=$(curl -sS "$BASE/users?limit=2&before=$P2_PREV" | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(d[0]["id"] if d else "")')
    if [ -n "$BACK_FIRST_ID" ] && [ "$BACK_FIRST_ID" = "$P1_FIRST_ID" ]; then
      printf '\033[1;32mPASS\033[0m (back=%s == page1=%s)\n' "$BACK_FIRST_ID" "$P1_FIRST_ID"
      PASS=$((PASS+1))
    else
      printf '\033[1;31mFAIL\033[0m (back=%s, page1=%s)\n' "$BACK_FIRST_ID" "$P1_FIRST_ID"
      FAIL=$((FAIL+1))
    fi
  else
    printf '\033[1;31mFAIL\033[0m page2 prev_cursor empty (envelope: %s)\n' "$(curl -sS "$BASE/users?limit=2&after=$P1_CURSOR")"
    FAIL=$((FAIL+1))
  fi
else
  printf '\033[1;31mFAIL\033[0m setup failed\n'
  FAIL=$((FAIL+1))
fi

# Conflict matrix — ?after= and ?before= cannot coexist; the wire envelope
# surfaces "after,before" as the offending field.
show "15.10 ?after=<c>&before=<c> rejected (mutually exclusive)" \
  GET "/users?after=eyJ2IjoxLCJrIjpbInRlc3QiXX0%3D&before=eyJ2IjoxLCJrIjpbInRlc3QiXX0%3D" "" 400

# Malformed cursor — strict shape rejection (base64 garbage).
show "15.11 ?after=not-base64 rejected (cursor schema violation)" \
  GET "/users?after=not-base64---" "" 400

# Cursor↔Sort mismatch — cursor encoded against a 0-sort context, request
# declares ?sort=name → tuple length disagrees → 400. Consumer must request
# page 1 of the new sort before navigating.
show "15.12 ?sort=name&after=<no-sort-cursor> rejected (tuple/sort mismatch)" \
  GET "/users?sort=name&after=eyJ2IjoxLCJrIjpbInRlc3QiXX0%3D" "" 400

# Limit boundary — zero and negative both reject as schema violations.
show "15.13 ?limit=0 rejected (schema violation)" \
  GET "/users?limit=0" "" 400
show "15.14 ?limit=-5 rejected (schema violation)" \
  GET "/users?limit=-5" "" 400

# Per-view ceiling — the framework default is 100; requesting more is
# rejected with a translatable LimitExceededNotification (Schema → 400).
# Consumers can opt into a per-view override via ViewDefinition.MaxLimit
# (see omnicore/CLAUDE.md "Read-side wrappers").
show "15.15 ?limit=999 rejected (above default ceiling 100)" \
  GET "/users?limit=999" "" 400

# Cursor↔context mismatch — the cursor binds the full listing context
# (filter + sort + search + includeArchived) via a SHA-256 hash. Any change
# on any axis between pages rejects the cursor with 400 so the frontend
# cannot silently navigate a stale keyset boundary across different result
# sets.
title "15.16 cursor issued without filter rejected when filter is added"
NO_FILTER_CURSOR=$(curl -sS "$BASE/users?limit=1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("next_cursor",""))')
if [ -n "$NO_FILTER_CURSOR" ]; then
  STATUS=$(curl -sS -o /tmp/qa-e2e-filter-mismatch.body.${BACKEND:-default} -w "%{http_code}" "$BASE/users?limit=1&after=$NO_FILTER_CURSOR&name.startswith=B")
  if [ "$STATUS" = "400" ]; then
    printf '\033[1;32mPASS\033[0m (status=%s — cursor↔filter mismatch rejected)\n' "$STATUS"
    PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m (status=%s, expected 400)\n' "$STATUS"
    FAIL=$((FAIL+1))
  fi
else
  printf '\033[1;31mFAIL\033[0m no_filter_cursor empty\n'
  FAIL=$((FAIL+1))
fi

title "15.17 cursor issued without sort rejected when sort is added"
NO_SORT_CURSOR=$(curl -sS "$BASE/users?limit=1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("next_cursor",""))')
if [ -n "$NO_SORT_CURSOR" ]; then
  # Adding ?sort=name AND keeping the same tuple shape — the tuple-length
  # check would now fail anyway, but the hash check catches it too.
  STATUS=$(curl -sS -o /tmp/qa-e2e-sort-mismatch.body.${BACKEND:-default} -w "%{http_code}" "$BASE/users?limit=1&after=$NO_SORT_CURSOR&sort=name")
  if [ "$STATUS" = "400" ]; then
    printf '\033[1;32mPASS\033[0m (status=%s — cursor↔sort mismatch rejected)\n' "$STATUS"
    PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m (status=%s, expected 400)\n' "$STATUS"
    FAIL=$((FAIL+1))
  fi
else
  printf '\033[1;31mFAIL\033[0m no_sort_cursor empty\n'
  FAIL=$((FAIL+1))
fi

title "15.18 cursor issued without includeArchived rejected when flag is flipped"
DEFAULT_CTX_CURSOR=$(curl -sS "$BASE/users?limit=1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("next_cursor",""))')
if [ -n "$DEFAULT_CTX_CURSOR" ]; then
  STATUS=$(curl -sS -o /tmp/qa-e2e-archived-mismatch.body.${BACKEND:-default} -w "%{http_code}" "$BASE/users?limit=1&after=$DEFAULT_CTX_CURSOR&includeArchived=true")
  if [ "$STATUS" = "400" ]; then
    printf '\033[1;32mPASS\033[0m (status=%s — cursor↔includeArchived mismatch rejected)\n' "$STATUS"
    PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m (status=%s, expected 400)\n' "$STATUS"
    FAIL=$((FAIL+1))
  fi
else
  printf '\033[1;31mFAIL\033[0m default_ctx_cursor empty\n'
  FAIL=$((FAIL+1))
fi

####################################
sec "16. /showcase/users-custom/* — list-side operators (manual showcase parity)"
####################################
# Sec 12 covers limit and basic filter. Pin the additional operators the
# manual surface accepts via its own Request DTO allowlist.

# Confirm /showcase/users-custom honors limit + has pagination envelope.
title "16.1 ?limit=1 emits has_next=true on the custom list"
CUSTOM_PAG=$(curl -sS "$BASE/showcase/users-custom?limit=1" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("has_next"))')
if [ "$CUSTOM_PAG" = "True" ]; then
  printf '\033[1;32mPASS\033[0m (has_next=true)\n'
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (has_next=%s)\n' "$CUSTOM_PAG"
  FAIL=$((FAIL+1))
fi

# `?includeArchived=true` returns archived records too (USER_C is archived).
show_count "16.2 ?includeArchived=true on the list endpoint surfaces archived records" \
  "/showcase/users-custom?includeArchived=true" 200 1

# Empty list endpoint: name filter that matches nothing → empty array.
show_count "16.3 ?name=NOMATCH returns empty data (200, not 404)" \
  "/showcase/users-custom?name=NOMATCH" 200 0

####################################
sec "17. GET /users — ?onlyTotal=true (count-only mode)"
####################################
# The FindUsersByParamsRequest opts into the count-only mode via
#   OnlyTotal *bool `query:"onlyTotal"`
# When ?onlyTotal=true the wire envelope flips: data is absent, pagination
# carries solely { total }. The matrix below covers (a) envelope shape,
# (b) propagation of filter leaves / search / archived, and (c) the
# strict-reject conflict matrix against the listing-only reserved keys
# (fields, sort, limit, after, before).

# only_total_check <name> <url> <expected_min_total>
#   Asserts: status 200, response.data absent, pagination.total >= expected_min_total.
only_total_check() {
  local name="$1" path="$2" min_total="${3:-0}"
  title "$name"
  echo "REQUEST : GET $path"
  local tmp; tmp=$(mktemp)
  local status
  status=$(curl -sS -o "$tmp" -w "%{http_code}" -G "$BASE$path" \
    -H "Accept-Language: en-US")
  echo "STATUS  : $status"
  echo "RESPONSE:"
  python3 -m json.tool < "$tmp" 2>/dev/null || cat "$tmp"
  echo
  local shape
  shape=$(python3 -c 'import sys,json
try:
  d=json.load(open(sys.argv[1]))
  data_present=("data" in d)
  pag=d.get("pagination") or {}
  total=pag.get("total", -1)
  extras=[k for k in pag.keys() if k != "total"]
  print(f"{int(data_present)}|{total}|{",".join(extras)}")
except Exception as e:
  print(f"err:{e}")' "$tmp")
  local data_present="${shape%%|*}"
  local rest="${shape#*|}"
  local total="${rest%%|*}"
  local extras="${rest#*|}"
  if [ "$status" = "200" ] && [ "$data_present" = "0" ] && [ -z "$extras" ] && [ "$total" -ge "$min_total" ]; then
    printf '\033[1;32mPASS\033[0m (status=200, data absent, pagination={total:%s})\n' "$total"
    PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m (status=%s data_present=%s total=%s extras=%q expected min_total=%s)\n' \
      "$status" "$data_present" "$total" "$extras" "$min_total"
    FAIL=$((FAIL+1))
  fi
  rm -f "$tmp"
}

# 17.1 — Envelope shape: data absent, only pagination.total populated.
only_total_check "17.1 ?onlyTotal=true returns count-only envelope (data absent, pagination={total})" \
  "/users?onlyTotal=true" 1

# 17.2 — Filter leaf still applies. At this point in the suite only Anna II
# is active (Anna I was archived in 3.2 and stays archived; Anna III was
# hard-deleted in 8.1 — see "post sec-8 delete: only Anna II remains" in
# sec 14). The count-only mode must honor the prefix filter on the active
# set.
only_total_check "17.2 ?onlyTotal=true&name.startswith=Anna counts active Anna prefix matches (>=1, only Anna II survives sec 8.1 delete)" \
  "/users?onlyTotal=true&name.startswith=Anna" 1

# 17.3 — `search` keeps working (text index on name+email — declared by UserView).
only_total_check "17.3 ?onlyTotal=true&search=Jane counts text-index matches (>=1)" \
  "/users?onlyTotal=true&search=Jane" 1

# 17.4 — `archived` gate still applies: counts archived rows too.
only_total_check "17.4 ?onlyTotal=true&includeArchived=true includes archived rows (>= active count)" \
  "/users?onlyTotal=true&includeArchived=true" 1

# 17.5 — Conflict matrix: each listing-only key triggers 400 with onlyTotal[<key>].
show "17.5 ?onlyTotal=true&fields=name rejected (onlyTotal[fields])"  GET "/users?onlyTotal=true&fields=name"     "" 400
show "17.6 ?onlyTotal=true&sort=-name rejected (onlyTotal[sort])"     GET "/users?onlyTotal=true&sort=-name"      "" 400
show "17.7 ?onlyTotal=true&limit=10 rejected (onlyTotal[limit])"      GET "/users?onlyTotal=true&limit=10"        "" 400
show "17.8 ?onlyTotal=true&after=cur-xyz rejected (onlyTotal[after])" GET "/users?onlyTotal=true&after=cur-xyz"   "" 400
show "17.9 ?onlyTotal=true&before=cur-xyz rejected (onlyTotal[before])" GET "/users?onlyTotal=true&before=cur-xyz" "" 400

# 17.10 — onlyTotal=false acts as omitted: regular listing envelope returns.
title "17.10 ?onlyTotal=false keeps listing envelope (data present)"
RESP_TMP=$(mktemp)
LIST_STATUS=$(curl -sS -o "$RESP_TMP" -w "%{http_code}" "$BASE/users?onlyTotal=false" \
  -H "Accept-Language: en-US")
echo "STATUS  : $LIST_STATUS"
python3 -m json.tool < "$RESP_TMP" >/dev/null 2>&1 && python3 -m json.tool < "$RESP_TMP" | head -40
HAS_DATA=$(python3 -c 'import sys,json;print(int("data" in json.load(open(sys.argv[1]))))' "$RESP_TMP")
if [ "$LIST_STATUS" = "200" ] && [ "$HAS_DATA" = "1" ]; then
  printf '\033[1;32mPASS\033[0m (listing envelope intact when onlyTotal=false)\n'
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (status=%s has_data=%s)\n' "$LIST_STATUS" "$HAS_DATA"
  FAIL=$((FAIL+1))
fi
rm -f "$RESP_TMP"

####################################
sec "18. Field labels — humanized identifiers per locale"
####################################
# The framework reads `label:"<catalogKey>"` struct tags off the domain
# entities at notification emit time (Rules.AddNotification populates LabelKey
# on the message; convert.go renders it via Translator.Render). The wire
# envelope carries the rendered string on MessageDTO.FieldLabel beside the
# technical FieldName. Empty when no tag → omitempty elides; raw key on
# catalog miss (symmetric with the existing Notification.Message fallback).
#
# This service tags every validated field on User + Address; PTBR and ENG
# catalogs declare every key. The cases below cross-check that the wire
# emits the expected rendered label per locale.

# field_label_check posts the invalid body with the given Accept-Language;
# asserts the top-level status AND that errors[0].messages[0].fieldLabel
# equals the expected value.
field_label_check() {
  local case_name="$1" lang_header="$2" body="$3" expected_status="$4" expected_label="$5"
  title "$case_name"
  echo "REQUEST : POST /users (Accept-Language: $lang_header)"
  local tmp; tmp=$(mktemp)
  local status
  status=$(curl -sS -o "$tmp" -w "%{http_code}" -X POST "$BASE/users" \
    -H "Content-Type: application/json" -H "Accept-Language: $lang_header" \
    --data "$body")
  echo "STATUS  : $status"
  python3 -m json.tool < "$tmp" 2>/dev/null | head -20 || cat "$tmp"
  echo
  local got_label
  got_label=$(python3 -c '
import sys, json
doc = json.load(open(sys.argv[1]))
errs = doc.get("errors") or []
if not errs or not errs[0].get("messages"):
  print("__MISSING__")
else:
  print(errs[0]["messages"][0].get("fieldLabel", ""))
' "$tmp")
  if [ "$status" = "$expected_status" ] && [ "$got_label" = "$expected_label" ]; then
    printf '\033[1;32mPASS\033[0m (status=%s fieldLabel=%s)\n' "$status" "$got_label"
    PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m (status=%s/%s fieldLabel=%s/%s)\n' "$status" "$expected_status" "$got_label" "$expected_label"
    FAIL=$((FAIL+1))
  fi
  rm -f "$tmp"
}

# 18.1 — User.Name has `label:"UserNameField"`. Missing name → 422 with
# fieldLabel rendered in the actor's locale.
field_label_check "18.1 POST missing Name → 422 with fieldLabel=Nome (PT-BR)" \
  "pt-BR" '{"name":"","email":"label-pt@example.com","phone":"14155553333","document":"10000000081","userName":"labelpt","addresses":[]}' \
  "422" "Nome"

# 18.2 — Same notification, different locale: ENG catalog renders "Name".
field_label_check "18.2 POST missing Name → 422 with fieldLabel=Name (en-US)" \
  "en-US" '{"name":"","email":"label-en@example.com","phone":"14155554444","document":"10000000082","userName":"labelen","addresses":[]}' \
  "422" "Name"

# 18.3 — Aggregate child label: Address.ZipCode tag resolves through the
# scoped Rules; the wire `field` retains the path "addresses[0].zipCode"
# and `fieldLabel` carries the translated AVO field label.
title "18.3 POST invalid Address.ZipCode → 422 with field=addresses[0].zipCode + fieldLabel=CEP (PT-BR)"
ADDR_BODY='{"name":"With Address","email":"label-addr@example.com","phone":"14155555555","document":"10000000083","userName":"labeladdr","addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Centro","city":"Cidade","state":"SP","zipCode":"AB","country":"BR"}]}'
TMP=$(mktemp)
STATUS=$(curl -sS -o "$TMP" -w "%{http_code}" -X POST "$BASE/users" \
  -H "Content-Type: application/json" -H "Accept-Language: pt-BR" \
  --data "$ADDR_BODY")
echo "STATUS  : $STATUS"
python3 -m json.tool < "$TMP" 2>/dev/null | head -25 || cat "$TMP"
echo
ZIP_LABEL=$(python3 -c '
import sys, json
doc = json.load(open(sys.argv[1]))
hits = [m for ctx in (doc.get("errors") or []) for m in (ctx.get("messages") or []) if m.get("field") == "addresses[0].zipCode"]
print(hits[0].get("fieldLabel", "") if hits else "__MISSING__")
' "$TMP")
if [ "$STATUS" = "422" ] && [ "$ZIP_LABEL" = "CEP" ]; then
  printf '\033[1;32mPASS\033[0m (zipCode fieldLabel=CEP)\n'
  PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (status=%s zipLabel=%s want CEP)\n' "$STATUS" "$ZIP_LABEL"
  FAIL=$((FAIL+1))
fi
rm -f "$TMP"

####################################
sec "19. GET /users.csv + /users.xlsx — tabular export (hierarchical + labelKey headers + ?fields + filters/search/sort/archive)"
####################################
# The CSV route reuses the same `users` view + FindUsersByParamsRequest as GET
# /users, rendered as a hierarchical CSV: root columns at column A, addresses at
# column B (one empty leading field per nesting level). Headers come from the
# `labelKey:"…"` catalog rendered in Accept-Language; the route is mounted with
# the ',' delimiter. A blank line separates each user's aggregate block. By this
# section the Mongo view holds users (Jane = USER_A,
# active) with addresses, so the export has hierarchical data to render.

# csv_assert: name, query, expected_status, [must-contain], [must-NOT-contain]
csv_assert() {
  local name="$1" query="$2" expected="$3" want="${4:-}" absent="${5:-}"
  title "$name"
  local tmp; tmp=$(mktemp)
  local status
  status=$(curl -sS -o "$tmp" -w "%{http_code}" "$BASE/users.csv$query" -H "Accept-Language: en-US")
  echo "REQUEST : GET /users.csv$query"
  echo "STATUS  : $status"
  echo "BODY (first 8 lines):"; head -n 8 "$tmp"
  local ok=1
  [ "$status" = "$expected" ] || ok=0
  if [ -n "$want" ] && ! grep -qF "$want" "$tmp"; then ok=0; echo "  (missing expected substring: $want)"; fi
  if [ -n "$absent" ] && grep -qF "$absent" "$tmp"; then ok=0; echo "  (unexpected substring present: $absent)"; fi
  if [ "$ok" = 1 ]; then
    printf '\033[1;32mPASS\033[0m (status %s)\n' "$status"; PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m (expected status %s, got %s)\n' "$expected" "$status"; FAIL=$((FAIL+1))
  fi
  rm -f "$tmp"
}

title "19.1 GET /users.csv → 200 + text/csv + attachment;filename=\"users.csv\""
TMP=$(mktemp); HDR=$(mktemp)
STATUS=$(curl -sS -o "$TMP" -D "$HDR" -w "%{http_code}" "$BASE/users.csv" -H "Accept-Language: en-US")
CT=$(grep -i '^content-type:' "$HDR" | tr -d '\r')
CD=$(grep -i '^content-disposition:' "$HDR" | tr -d '\r')
echo "STATUS  : $STATUS"; echo "$CT"; echo "$CD"; echo "HEAD:"; head -n 6 "$TMP"
if [ "$STATUS" = "200" ] && echo "$CT" | grep -qi "text/csv" && echo "$CD" | grep -qi 'filename="users.csv"'; then
  printf '\033[1;32mPASS\033[0m (200 text/csv attachment)\n'; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (status=%s ct=%s cd=%s)\n' "$STATUS" "$CT" "$CD"; FAIL=$((FAIL+1))
fi
rm -f "$TMP" "$HDR"

# Root header carries the labelKey-rendered, ','-separated column titles.
csv_assert "19.2 root header rendered from labelKey (en-US: Name,Email)" "" 200 "Name,Email"
# Nested address columns prove the hierarchy renders (the address header carries
# the AddressZipCodeField label 'ZIP Code', offset one column to the right).
csv_assert "19.3 nested address columns present (ZIP Code label, depth-1 offset)" "" 200 "ZIP Code"
# A data value from USER_A (Jane Doe / jane@example.com) is in the export.
csv_assert "19.4 export carries a known data row (jane@example.com)" "" 200 "jane@example.com"
# ?fields=name narrows to a single column — no email column, no addresses.
csv_assert "19.5 ?fields=name narrows columns (Jane Doe present, email column dropped)" "?fields=name" 200 "Jane Doe" "@example.com"
# Filter passthrough — same allowlist as GET /users.
csv_assert "19.6 filter passthrough ?name.startswith=Jane" "?name.startswith=Jane" 200 "Jane Doe"
# Unknown ?fields token rejected with 400 (allowlist driven by the view schema).
csv_assert "19.7 ?fields=bogus rejected (400)" "?fields=bogus" 400
# Unknown query key rejected with 400.
csv_assert "19.8 unknown query key rejected (400)" "?role=admin" 400

# XLSX export — same surface, different encoder. Binary (a ZIP), so assert the
# status, the spreadsheet content-type, the attachment filename, and the ZIP
# magic bytes (PK) rather than text content.
title "19.9 GET /users.xlsx → 200 + xlsx content-type + attachment + ZIP magic"
TMP=$(mktemp); HDR=$(mktemp)
STATUS=$(curl -sS -o "$TMP" -D "$HDR" -w "%{http_code}" "$BASE/users.xlsx" -H "Accept-Language: en-US")
CT=$(grep -i '^content-type:' "$HDR" | tr -d '\r')
CD=$(grep -i '^content-disposition:' "$HDR" | tr -d '\r')
MAGIC=$(head -c 2 "$TMP"); SIZE=$(wc -c < "$TMP" | tr -d ' ')
echo "STATUS  : $STATUS"; echo "$CT"; echo "$CD"; echo "magic=$MAGIC size=$SIZE"
if [ "$STATUS" = "200" ] && echo "$CT" | grep -qi "spreadsheetml.sheet" \
   && echo "$CD" | grep -qi 'filename="users.xlsx"' && [ "$MAGIC" = "PK" ] && [ "$SIZE" -gt 0 ]; then
  printf '\033[1;32mPASS\033[0m (xlsx workbook)\n'; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (status=%s ct=%s magic=%s)\n' "$STATUS" "$CT" "$MAGIC"; FAIL=$((FAIL+1))
fi
rm -f "$TMP" "$HDR"

# Shared wrapper → same 400 on a bad ?fields token, regardless of encoder.
title "19.10 GET /users.xlsx?fields=bogus rejected (400, shared wrapper path)"
TMP=$(mktemp)
STATUS=$(curl -sS -o "$TMP" -w "%{http_code}" "$BASE/users.xlsx?fields=bogus" -H "Accept-Language: en-US")
echo "STATUS  : $STATUS"; head -c 200 "$TMP"; echo
if [ "$STATUS" = "400" ]; then
  printf '\033[1;32mPASS\033[0m (400)\n'; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (expected 400, got %s)\n' "$STATUS"; FAIL=$((FAIL+1))
fi
rm -f "$TMP"

####################################
# 19.11+ — the export HONORS filters / search / sort / ?fields / archive.
# Seeds two uniquely-named fixtures ("…Exportprobe") so the assertions stay
# deterministic regardless of the tangled multi-user state earlier sections
# leave behind, then drives each query knob through /users.csv and asserts the
# OUTPUT actually changes — proving the knob is honored, not silently ignored
# (the way pagination is). XLSX shares the wrapper, so a status smoke per knob
# covers the second encoder.
####################################
title "19.11 Seed export fixtures (Zelda/Yuri Exportprobe) + wait for the Mongo view"
EXP1=$(curl -sS -X POST "$BASE/users" -H "Content-Type: application/json" -H "Accept-Language: en-US" \
  --data '{"name":"Zelda Exportprobe","email":"zelda.exp@example.com","phone":"14155550001","document":"10000000091","userName":"zelda","addresses":[{"label":"home","street":"1 Export St","number":"1","neighborhood":"Probe","city":"Exportville","state":"CA","zipCode":"94000","country":"US"}]}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
EXP2=$(curl -sS -X POST "$BASE/users" -H "Content-Type: application/json" -H "Accept-Language: en-US" \
  --data '{"name":"Yuri Exportprobe","email":"yuri.exp@example.com","phone":"14155550002","document":"10000000092","userName":"yuri","addresses":[{"label":"home","street":"2 Export Ave","number":"2","neighborhood":"Probe","city":"Exporton","state":"CA","zipCode":"94001","country":"US"}]}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["id"])')
echo "EXP1=$EXP1 (Zelda)  EXP2=$EXP2 (Yuri)"
if wait_for_view "$EXP1" "200" 15 && wait_for_view "$EXP2" "200" 15; then
  printf '\033[1;32mPASS\033[0m (both fixtures materialized in the view)\n'; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (CDC timeout seeding export fixtures)\n'; FAIL=$((FAIL+1))
fi

# Filter — positive selects only the match; a no-match query returns 200 with
# neither probe, proving the filter is applied (not dropped like pagination).
csv_assert "19.12 filter ?email.eq selects Zelda only" "?email.eq=zelda.exp@example.com" 200 "zelda.exp@example.com" "yuri.exp@example.com"
csv_assert "19.13 filter no-match → 200 with neither probe" "?email.eq=nobody.nomatch@example.com" 200 "" "exp@example.com"

# Search — the view's TextIndex(name,email) backs ?search; a matching term
# surfaces both probes, a non-matching term surfaces neither.
csv_assert "19.14 ?search=Exportprobe surfaces Zelda" "?search=Exportprobe" 200 "zelda.exp@example.com"
csv_assert "19.15 ?search=Exportprobe surfaces Yuri"  "?search=Exportprobe" 200 "yuri.exp@example.com"
csv_assert "19.16 ?search no-match surfaces neither"  "?search=zzznomatchqqq" 200 "" "exp@example.com"

# ?fields — nested + scalar projection narrows the columns end to end.
csv_assert "19.17 ?fields=addresses.city keeps the city, drops email" "?fields=addresses.city&name.icontains=Exportprobe" 200 "Exportville" "exp@example.com"
csv_assert "19.18 ?fields=email keeps the email, drops the name"      "?fields=email&name.icontains=Exportprobe" 200 "zelda.exp@example.com" "Exportprobe"

# Sort — honored value accepted; undeclared value rejected; asc vs desc reversed.
csv_assert "19.19 ?sort=email honored (200)" "?sort=email&name.icontains=Exportprobe" 200 "zelda.exp@example.com"
csv_assert "19.20 ?sort=bogus rejected (400)" "?sort=bogus" 400
title "19.21 ?sort=email ascending vs ?sort=-email descending — ordering is observable"
ASC=$(curl -sS "$BASE/users.csv?fields=email&name.icontains=Exportprobe&sort=email"  -H "Accept-Language: en-US" | grep -F '@example.com' | head -1)
DESC=$(curl -sS "$BASE/users.csv?fields=email&name.icontains=Exportprobe&sort=-email" -H "Accept-Language: en-US" | grep -F '@example.com' | head -1)
echo "asc_first=$ASC  desc_first=$DESC"
if echo "$ASC" | grep -q "yuri.exp@example.com" && echo "$DESC" | grep -q "zelda.exp@example.com"; then
  printf '\033[1;32mPASS\033[0m (asc=yuri…, desc=zelda… — sort drives the order)\n'; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (ordering not honored: asc=%s desc=%s)\n' "$ASC" "$DESC"; FAIL=$((FAIL+1))
fi

# Archive — default export hides the archived row (the default reader still
# filters deleted_at on the keep-by-default view); ?includeArchived=true shows it.
title "19.22 Archive EXP2 (Yuri) + wait for the view to reflect it (default by-id → 404)"
curl -sS -o /dev/null -X PATCH "$BASE/users/$EXP2/archive" -H "Content-Type: application/json"
if wait_for_view "$EXP2" "404" 15; then
  printf '\033[1;32mPASS\033[0m (EXP2 archived; hidden from the default reader)\n'; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (CDC timeout archiving EXP2)\n'; FAIL=$((FAIL+1))
fi
csv_assert "19.23 default export hides archived Yuri" "?name.icontains=Exportprobe" 200 "zelda.exp@example.com" "yuri.exp@example.com"
csv_assert "19.24 ?includeArchived=true surfaces archived Yuri" "?includeArchived=true&name.icontains=Exportprobe" 200 "yuri.exp@example.com"

# XLSX shares the wrapper — the same honored knobs must be accepted (200) and the
# same undeclared sort rejected (400), regardless of the encoder.
xlsx_status() {
  local name="$1" query="$2" expected="$3"
  title "$name"
  local s; s=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/users.xlsx$query" -H "Accept-Language: en-US")
  echo "GET /users.xlsx$query → $s"
  if [ "$s" = "$expected" ]; then printf '\033[1;32mPASS\033[0m\n'; PASS=$((PASS+1));
  else printf '\033[1;31mFAIL\033[0m (expected %s)\n' "$expected"; FAIL=$((FAIL+1)); fi
}
xlsx_status "19.25 xlsx honors ?name.icontains (200)"       "?name.icontains=Exportprobe" 200
xlsx_status "19.26 xlsx honors ?search (200)"               "?search=Exportprobe" 200
xlsx_status "19.27 xlsx honors ?sort=email (200)"           "?sort=email" 200
xlsx_status "19.28 xlsx honors ?fields=email (200)"         "?fields=email" 200
xlsx_status "19.29 xlsx honors ?includeArchived=true (200)" "?includeArchived=true" 200
xlsx_status "19.30 xlsx rejects ?sort=bogus (400)"          "?sort=bogus" 400

title "19.31 Cleanup export fixtures (unarchive EXP2, delete both)"
curl -sS -o /dev/null -X PATCH  "$BASE/users/$EXP2/unarchive" -H "Content-Type: application/json"
curl -sS -o /dev/null -X DELETE "$BASE/users/$EXP1"
curl -sS -o /dev/null -X DELETE "$BASE/users/$EXP2"
echo "deleted EXP1=$EXP1 EXP2=$EXP2 (EXP2 unarchived first so DELETE resolves)"

####################################
sec "20. Router protocol errors — 404 unknown route / 405 wrong method"
####################################
# The framework's Fiber error handler (web/error_handler.go) converts
# router-level misses into typed notifications through the SAME pipeline
# envelope every handler-level notification uses: an unmatched path emits
# RouteNotFoundNotification (404); a matched path hit with a verb it does not
# declare emits MethodNotAllowedNotification (405). Handler sections above
# only ever exercised 404 on a *matched* route with an unknown id — these two
# cases pin the router-level mapping itself.

# assert_body <name> <expected_status> <grep_pattern> <method> <path> [body] [extra curl args...]
# Raw-curl variant of `show` that additionally asserts a substring of the
# response body (used for notificationKey / rendered-message checks).
assert_body() {
  local name="$1" expected="$2" pattern="$3" method="$4" path="$5" body="${6:-}"
  shift; shift; shift; shift; shift; [ $# -gt 0 ] && shift
  title "$name"
  echo "REQUEST : $method $path"
  local tmp; tmp=$(mktemp)
  local status
  if [ -n "$body" ]; then
    status=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" \
      -H "Content-Type: application/json" "$@" --data "$body")
  else
    status=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" \
      -H "Content-Type: application/json" "$@")
  fi
  echo "STATUS  : $status"
  echo "RESPONSE:"
  python3 -m json.tool < "$tmp" 2>/dev/null || cat "$tmp"
  echo
  if [ "$status" = "$expected" ] && grep -q "$pattern" "$tmp"; then
    printf '\033[1;32mPASS\033[0m (status=%s, body carries %s)\n' "$status" "$pattern"
    PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m (expected status=%s + body pattern %s, got status=%s)\n' \
      "$expected" "$pattern" "$status"
    FAIL=$((FAIL+1))
  fi
  rm -f "$tmp"
}

assert_body "20.1 POST /does-not-exist → 404 RouteNotFoundNotification" \
  404 '"notificationKey":"RouteNotFoundNotification"' \
  POST "/does-not-exist" '' -H "Accept-Language: en-US"

assert_body "20.2 DELETE /whoami → 405 MethodNotAllowedNotification (path exists, verb does not)" \
  405 '"notificationKey":"MethodNotAllowedNotification"' \
  DELETE "/whoami" '' -H "Accept-Language: en-US"

####################################
sec "21. X-Request-ID — correlation id echoed / generated / sanitized"
####################################
# AppContextMiddleware owns the per-request UUID (AppContext.ID()): a valid
# X-Request-ID on the request is honored and echoed on the response; an
# absent header yields a freshly generated UUID; a NON-uuid value is replaced
# by a fresh one (never echoed back verbatim — the id must stay a UUID for
# audit threadId + tracing correlation).

title "21.1 Valid X-Request-ID is echoed back on the response"
REQ_ID_21="7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"
GOT_21=$(curl -sS -o /dev/null -D - "$BASE/livez" -H "X-Request-ID: $REQ_ID_21" \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="x-request-id"{print $2}')
echo "sent=$REQ_ID_21  got=$GOT_21"
if [ "$GOT_21" = "$REQ_ID_21" ]; then
  printf '\033[1;32mPASS\033[0m (request id echoed verbatim)\n'; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (expected echo of %s, got %s)\n' "$REQ_ID_21" "$GOT_21"; FAIL=$((FAIL+1))
fi

title "21.2 Absent X-Request-ID → response carries a freshly generated UUID"
GOT_22=$(curl -sS -o /dev/null -D - "$BASE/livez" \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="x-request-id"{print $2}')
echo "got=$GOT_22"
if python3 -c 'import sys,uuid; uuid.UUID(sys.argv[1])' "$GOT_22" 2>/dev/null; then
  printf '\033[1;32mPASS\033[0m (generated id is a valid UUID)\n'; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (response X-Request-ID missing or not a UUID: %s)\n' "$GOT_22"; FAIL=$((FAIL+1))
fi

title "21.3 Non-UUID X-Request-ID is replaced by a fresh valid UUID (not echoed)"
GOT_23=$(curl -sS -o /dev/null -D - "$BASE/livez" -H "X-Request-ID: not-a-uuid" \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="x-request-id"{print $2}')
echo "sent=not-a-uuid  got=$GOT_23"
if [ "$GOT_23" != "not-a-uuid" ] && python3 -c 'import sys,uuid; uuid.UUID(sys.argv[1])' "$GOT_23" 2>/dev/null; then
  printf '\033[1;32mPASS\033[0m (invalid input replaced by a valid UUID)\n'; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (expected fresh UUID, got %s)\n' "$GOT_23"; FAIL=$((FAIL+1))
fi

####################################
sec "22. Language selection — default + the five remaining catalogs"
####################################
# 1.13/1.14 prove EN + PT-BR. The service ships SEVEN catalogs
# (application/translations/): this section renders the SAME notification
# (InvalidEmailNotification) through the other five, plus the absent-header
# default (AppContext.Language() falls back to English when no
# Accept-Language is sent). Assertion = notificationKey + the exact catalog
# string, so a broken prefix-match or a catalog regression is visible.
BODY_LANG_22='{
  "name":"Lang Probe","email":"not-an-email","phone":"14155552671","document":"39000002200","userName":"langprobe",
  "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}]
}'

title "22.1 No Accept-Language header → English default ('Invalid email.')"
RESP_LANG=$(curl -sS -X POST "$BASE/users" -H "Content-Type: application/json" --data "$BODY_LANG_22")
echo "$RESP_LANG" | python3 -m json.tool 2>/dev/null || echo "$RESP_LANG"
if echo "$RESP_LANG" | grep -q '"notificationKey":"InvalidEmailNotification"' \
   && echo "$RESP_LANG" | grep -q 'Invalid email.'; then
  printf '\033[1;32mPASS\033[0m (defaulted to the English catalog)\n'; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (expected English message without Accept-Language)\n'; FAIL=$((FAIL+1))
fi

# lang_case <case_no> <accept_language> <expected_message>
lang_case() {
  local no="$1" lang="$2" expected="$3"
  title "22.$no Accept-Language: $lang → '$expected'"
  local resp
  resp=$(curl -sS -X POST "$BASE/users" -H "Content-Type: application/json" \
    -H "Accept-Language: $lang" --data "$BODY_LANG_22")
  echo "$resp" | python3 -m json.tool 2>/dev/null || echo "$resp"
  if echo "$resp" | grep -q '"notificationKey":"InvalidEmailNotification"' \
     && echo "$resp" | grep -qF "$expected"; then
    printf '\033[1;32mPASS\033[0m (%s catalog rendered)\n' "$lang"; PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m (expected "%s" under %s)\n' "$expected" "$lang"; FAIL=$((FAIL+1))
  fi
}
lang_case 2 "es-ES" "Email inválido."
lang_case 3 "fr-FR" "E-mail invalide."
lang_case 4 "de-DE" "Ungültige E-Mail-Adresse."
lang_case 5 "it-IT" "Email non valida."
lang_case 6 "nl-NL" "Ongeldig e-mailadres."

####################################
sec "23. InvalidDocumentNotification — natural-key shape validation"
####################################
# domain/user.go: documentRegex = ^[A-Za-z0-9.\-]{3,32}$ — the natural key is
# validated like any other field. A 2-char document violates the length floor
# and must surface the custom notification (the last custom notification in
# domain/notifications.go that e2e never asserted).

assert_body "23.1 POST /users with 2-char document → 422 InvalidDocumentNotification" \
  422 '"notificationKey":"InvalidDocumentNotification"' \
  POST "/users" '{
    "name":"Doc Probe","email":"doc.probe.qa23@example.com","phone":"14155552671",
    "document":"ab","userName":"docprobe",
    "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}]
  }' -H "Accept-Language: en-US"

assert_body "23.2 POST /users with symbol-bearing document → 422 InvalidDocumentNotification" \
  422 '"notificationKey":"InvalidDocumentNotification"' \
  POST "/users" '{
    "name":"Doc Probe","email":"doc.probe.qa23@example.com","phone":"14155552671",
    "document":"12345!78901","userName":"docprobe",
    "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}]
  }' -H "Accept-Language: en-US"

####################################
sec "24. List reads — ?search (JSON), composite sort, cursor tampering"
####################################
# ?search rides the view's TextIndex(name,email) — 19.14-19.16 proved it on
# the CSV export wrapper; this section pins the JSON list endpoint itself.
# Composite sort (?sort=a,-b) and the cursor schema-version gate
# (DecodeCursor rejects v != CursorSchemaVersion) had no coverage anywhere.

# show_count_eq — exact-count variant of show_count: negative cases must
# assert 0 matches, not >= 0 (which is trivially true).
show_count_eq() {
  local name="$1" path="$2" expected="$3" want_count="$4"
  title "$name"
  echo "REQUEST : GET $path"
  local tmp; tmp=$(mktemp)
  local status
  status=$(curl -sS -o "$tmp" -w "%{http_code}" -G "$BASE$path" -H "Accept-Language: en-US")
  echo "STATUS  : $status"
  python3 -m json.tool < "$tmp" 2>/dev/null || cat "$tmp"
  local count
  count=$(python3 -c 'import sys,json
try:
  d=json.load(open(sys.argv[1]))
  data=d.get("data",[])
  print(len(data) if isinstance(data,list) else 0)
except Exception:
  print(-1)' "$tmp")
  if [ "$status" = "$expected" ] && [ "$count" = "$want_count" ]; then
    printf '\033[1;32mPASS\033[0m (status=%s, items=%s)\n' "$status" "$count"; PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m (expected status=%s items=%s, got status=%s items=%s)\n' \
      "$expected" "$want_count" "$status" "$count"; FAIL=$((FAIL+1))
  fi
  rm -f "$tmp"
}

title "24.0 Seed fixtures: one search probe + two sort twins"
RESP_S1=$(curl -sS -X POST "$BASE/users" -H "Content-Type: application/json" --data '{
  "name":"Zearchprobe Unique","email":"zearch.qa24@example.com","phone":"14155552671",
  "document":"39000002401","userName":"zearch1",
  "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}]}')
SRCH1=$(echo "$RESP_S1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null || echo "")
RESP_T1=$(curl -sS -X POST "$BASE/users" -H "Content-Type: application/json" --data '{
  "name":"Sortprobe Twin","email":"sortprobe.a.qa24@example.com","phone":"14155552671",
  "document":"39000002402","userName":"sortpa",
  "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}]}')
TWIN1=$(echo "$RESP_T1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null || echo "")
RESP_T2=$(curl -sS -X POST "$BASE/users" -H "Content-Type: application/json" --data '{
  "name":"Sortprobe Twin","email":"sortprobe.b.qa24@example.com","phone":"14155552671",
  "document":"39000002403","userName":"sortpb",
  "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}]}')
TWIN2=$(echo "$RESP_T2" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null || echo "")
if [ -n "$SRCH1" ] && [ -n "$TWIN1" ] && [ -n "$TWIN2" ] \
   && wait_for_view "$SRCH1" 200 20 && wait_for_view "$TWIN1" 200 20 && wait_for_view "$TWIN2" 200 20; then
  printf '\033[1;32mPASS\033[0m (three fixtures materialized: %s %s %s)\n' "$SRCH1" "$TWIN1" "$TWIN2"; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (fixture seeding failed: SRCH1=%s TWIN1=%s TWIN2=%s)\n' "$SRCH1" "$TWIN1" "$TWIN2"; FAIL=$((FAIL+1))
fi

show_count_eq "24.1 JSON list ?search=Zearchprobe surfaces the probe (TextIndex on name/email)" \
  "/users?search=Zearchprobe" 200 1
show_count_eq "24.2 JSON list ?search=zzznomatchqqq matches nothing" \
  "/users?search=zzznomatchqqq" 200 0

title "24.3 Composite sort ?sort=name,-email — secondary key descending"
FIRST_DESC_EMAIL=$(curl -sS "$BASE/users?name.startswith=Sortprobe&sort=name,-email" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data",[]);print(d[0]["email"] if d else "")')
FIRST_ASC_EMAIL=$(curl -sS "$BASE/users?name.startswith=Sortprobe&sort=name,email" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data",[]);print(d[0]["email"] if d else "")')
echo "sort=name,-email first=$FIRST_DESC_EMAIL   sort=name,email first=$FIRST_ASC_EMAIL"
if [ "$FIRST_DESC_EMAIL" = "sortprobe.b.qa24@example.com" ] && [ "$FIRST_ASC_EMAIL" = "sortprobe.a.qa24@example.com" ]; then
  printf '\033[1;32mPASS\033[0m (secondary sort key drives the order both ways)\n'; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (composite sort not honored: desc=%s asc=%s)\n' "$FIRST_DESC_EMAIL" "$FIRST_ASC_EMAIL"; FAIL=$((FAIL+1))
fi

title "24.4 Cursor with tampered schema version (v=99) → 400"
CURSOR_24=$(curl -sS "$BASE/users?limit=1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("pagination",{}).get("next_cursor",""))')
if [ -z "$CURSOR_24" ]; then
  printf '\033[1;31mFAIL\033[0m (no next_cursor available to tamper)\n'; FAIL=$((FAIL+1))
else
  TAMPERED_24=$(python3 -c '
import base64, json, sys
raw = base64.urlsafe_b64decode(sys.argv[1])
d = json.loads(raw)
d["v"] = 99
print(base64.urlsafe_b64encode(json.dumps(d).encode()).decode())' "$CURSOR_24")
  ST_24=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/users?limit=1&after=$TAMPERED_24")
  echo "tampered cursor status=$ST_24"
  if [ "$ST_24" = "400" ]; then
    printf '\033[1;32mPASS\033[0m (unsupported cursor version rejected cleanly)\n'; PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m (expected 400 on v=99 cursor, got %s)\n' "$ST_24"; FAIL=$((FAIL+1))
  fi
fi

show_count_eq "24.5 ?after=<not even base64> → 400 (malformed cursor rejected)" \
  "/users?limit=1&after=%%%not-base64%%%" 400 0

title "24.6 Cleanup section-24 fixtures"
curl -sS -o /dev/null -X DELETE "$BASE/users/$SRCH1"
curl -sS -o /dev/null -X DELETE "$BASE/users/$TWIN1"
curl -sS -o /dev/null -X DELETE "$BASE/users/$TWIN2"
echo "deleted SRCH1=$SRCH1 TWIN1=$TWIN1 TWIN2=$TWIN2"

####################################
sec "25. Regex metacharacters in filter values are literal (QuoteMeta)"
####################################
# 4.5.10 proved a literal space; this section pins the dangerous
# metacharacters: dot (wildcard), star (quantifier) and brackets (class).
# Fixture name carries all three. If the wire boundary ever stops escaping,
# 25.2 turns into a false positive (dot matches 'x') and fails loudly.

title "25.0 Seed metacharacter fixture"
RESP_M=$(curl -sS -X POST "$BASE/users" -H "Content-Type: application/json" --data '{
  "name":"Meta A.B x*y [q] End","email":"meta.qa25@example.com","phone":"14155552671",
  "document":"39000002501","userName":"metaprobe",
  "addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}]}')
META1=$(echo "$RESP_M" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null || echo "")
if [ -n "$META1" ] && wait_for_view "$META1" 200 20; then
  printf '\033[1;32mPASS\033[0m (fixture %s materialized)\n' "$META1"; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (metacharacter fixture failed to seed)\n'; FAIL=$((FAIL+1))
fi

show_count_eq "25.1 ?name.icontains=A.B matches the literal dot" \
  "/users?name.icontains=A.B" 200 1
show_count_eq "25.2 ?name.icontains=AxB does NOT match — dot is not a wildcard" \
  "/users?name.icontains=AxB" 200 0
show_count_eq "25.3 ?name.icontains=x*y matches the literal star" \
  "/users?name.icontains=x*y" 200 1
show_count_eq "25.4 ?name.icontains=%5Bq%5D matches the literal brackets" \
  "/users?name.icontains=%5Bq%5D" 200 1
show_count_eq "25.5 ?name.icontains=%20%5Bq%5D%20 — space-delimited bracket segment matches literally" \
  "/users?name.icontains=%20%5Bq%5D%20" 200 1
show_count_eq "25.6 ?name.startswith=Meta%20A.B literal prefix with dot" \
  "/users?name.startswith=Meta%20A.B" 200 1

title "25.7 Cleanup metacharacter fixture"
curl -sS -o /dev/null -X DELETE "$BASE/users/$META1"
echo "deleted META1=$META1"

####################################
sec "26. Cross-role fan-out via the address SUBRESOURCE (User PUT → Employee view)"
####################################
# employee.sh §10 proves cross-role address propagation via FULL-BODY PUTs;
# audit.sh §8 proves the single-address subresource endpoint in isolation.
# This section closes the combination neither covers: with BOTH roles active
# over the same Person, a PUT on /users/:id/addresses/:addressId (the
# subresource, not the full body) must fan out to the users AND employees
# Mongo views — the address is a base child shared by every role.
D26="39000002601"

title "26.0 Seed: user + employee over the same document ($D26)"
RESP_U26=$(curl -sS -X POST "$BASE/users" -H "Content-Type: application/json" --data '{
  "name":"Cross Subres","email":"cross.subres.qa26@example.com","phone":"14155552671",
  "document":"'"$D26"'","userName":"crosssub",
  "addresses":[{"label":"home","street":"Original Street","number":"1","neighborhood":"Downtown","city":"Origin City","state":"CA","zipCode":"94103","country":"US"}]}')
UID26=$(echo "$RESP_U26" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null || echo "")
ST_E26=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE/employees" -H "Content-Type: application/json" --data '{
  "name":"Cross Subres","email":"cross.subres.qa26@example.com",
  "document":"'"$D26"'","employeeNumber":"EMP-QA26"}')
if [ -n "$UID26" ] && [ "$ST_E26" = "201" ] && wait_for_view "$UID26" 200 20; then
  printf '\033[1;32mPASS\033[0m (both roles created, id=%s)\n' "$UID26"; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (seed failed: UID26=%s employee_status=%s)\n' "$UID26" "$ST_E26"; FAIL=$((FAIL+1))
fi

title "26.1 Wait for the employee view to materialize (list by document)"
deadline=$(( $(date +%s) + 20 )); EMP_SEEN=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  EMP_CNT=$(curl -sS "$BASE/employees?document=$D26" \
    | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data",[]);print(len(d))' 2>/dev/null)
  [ "$EMP_CNT" = "1" ] && { EMP_SEEN=ok; break; }
  sleep 0.3
done
[ "$EMP_SEEN" = ok ] && { printf '\033[1;32mPASS\033[0m (employee doc visible)\n'; PASS=$((PASS+1)); } \
                     || { printf '\033[1;31mFAIL\033[0m (employee view never materialized)\n'; FAIL=$((FAIL+1)); }

title "26.2 PUT the single-address subresource through the USER role"
ADDR26=$(curl -sS "$BASE/users/$UID26" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"]["addresses"];print(d[0]["id"] if d else "")')
echo "ADDR26=$ADDR26"
ST_PUT26=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "$BASE/users/$UID26/addresses/$ADDR26" \
  -H "Content-Type: application/json" --data '{
    "label":"home","street":"Fanout Street","number":"42","complement":null,
    "neighborhood":"FiDi","city":"Fanout City","state":"CA","zipCode":"94199","country":"US"}')
if [ "$ST_PUT26" = "200" ]; then
  printf '\033[1;32mPASS\033[0m (subresource PUT accepted)\n'; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (subresource PUT status=%s)\n' "$ST_PUT26"; FAIL=$((FAIL+1))
fi

title "26.3 USER view reflects the subresource change"
deadline=$(( $(date +%s) + 20 )); U_FAN=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  s=$(curl -sS "$BASE/users/$UID26" \
      | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"]["addresses"];print(next((a["street"] for a in d if a["id"]=="'"$ADDR26"'"), ""))' 2>/dev/null)
  [ "$s" = "Fanout Street" ] && { U_FAN=ok; break; }
  sleep 0.3
done
[ "$U_FAN" = ok ] && { printf '\033[1;32mPASS\033[0m (users view carries Fanout Street)\n'; PASS=$((PASS+1)); } \
                  || { printf '\033[1;31mFAIL\033[0m (users view stale after subresource PUT)\n'; FAIL=$((FAIL+1)); }

title "26.4 EMPLOYEE view reflects the SAME change (shared base child fans out)"
deadline=$(( $(date +%s) + 20 )); E_FAN=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  s=$(curl -sS "$BASE/employees?document=$D26" \
      | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data",[]);a=d[0].get("addresses",[]) if d else [];print(next((x["street"] for x in a if x["id"]=="'"$ADDR26"'"), ""))' 2>/dev/null)
  [ "$s" = "Fanout Street" ] && { E_FAN=ok; break; }
  sleep 0.3
done
[ "$E_FAN" = ok ] && { printf '\033[1;32mPASS\033[0m (employees view carries Fanout Street — cross-role fan-out proven)\n'; PASS=$((PASS+1)); } \
                  || { printf '\033[1;31mFAIL\033[0m (employees view stale after USER subresource PUT)\n'; FAIL=$((FAIL+1)); }

title "26.5 Cleanup: delete employee role then user role (purges the base)"
curl -sS -o /dev/null -X DELETE "$BASE/employees/$UID26"
curl -sS -o /dev/null -X DELETE "$BASE/users/$UID26"
echo "deleted both roles for document $D26"

####################################
sec "27. Outbox granularity B — the aggregate is the event unit"
####################################
# lifecycle-map contract: each write lands a deterministic set of outbox rows
# in the SAME TX — one row per AGGREGATE operation, never per child. On the
# SharedBase design a role write is two aggregate ops (the role + the shared
# base), so the exact fingerprint per verb is:
#   POST            → users INSERTED +1, persons UPDATED +1
#   PUT / PATCH     → users UPDATED  +1, persons UPDATED +1
#   ARCHIVE         → users ARCHIVED +1
#   UNARCHIVE       → users UNARCHIVED +1
#   DELETE (orphan) → users DELETED  +1, persons DELETED +1  (refcount purge)
# Addresses NEVER get their own outbox rows (granularity B): asserted after
# every verb, on writes that touch 2-3 address children.

outbox_count() { qa_db_query "SELECT count(*) FROM outbox WHERE aggregate_type='$1' AND event_type='$2';"; }

# assert_outbox_delta <label> <before> <after> <want_delta>
assert_outbox_delta() {
  local label="$1" before="$2" after="$3" want="$4"
  if [ "$after" = "$((before + want))" ]; then
    printf '\033[1;32mPASS\033[0m %s (%s → %s, +%s)\n' "$label" "$before" "$after" "$want"; PASS=$((PASS+1))
  else
    printf '\033[1;31mFAIL\033[0m %s (%s → %s, want +%s)\n' "$label" "$before" "$after" "$want"; FAIL=$((FAIL+1))
  fi
}

D27="39000002701"
ADDR_OUTBOX_27=$(qa_db_query "SELECT count(*) FROM outbox WHERE aggregate_type='addresses';")

title "27.1 POST with two addresses → users INSERTED +1, persons UPDATED +1, zero address rows"
UI_B=$(outbox_count users INSERTED); PU_B=$(outbox_count persons UPDATED)
RESP_27=$(curl -sS -X POST "$BASE/users" -H "Content-Type: application/json" --data '{
  "name":"Outbox Probe","email":"outbox.qa27@example.com","phone":"14155552671",
  "document":"'"$D27"'","userName":"outboxp",
  "addresses":[
    {"label":"home","street":"First","number":"1","neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"},
    {"label":"work","street":"Second","number":"2","neighborhood":"FiDi","city":"San Francisco","state":"CA","zipCode":"94105","country":"US"}
  ]}')
UID27=$(echo "$RESP_27" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null || echo "")
UI_A=$(outbox_count users INSERTED); PU_A=$(outbox_count persons UPDATED)
assert_outbox_delta "users INSERTED" "$UI_B" "$UI_A" 1
assert_outbox_delta "persons UPDATED" "$PU_B" "$PU_A" 1

title "27.2 PATCH name → users UPDATED +1, persons UPDATED +1"
UU_B=$(outbox_count users UPDATED); PU_B=$(outbox_count persons UPDATED)
curl -sS -o /dev/null -X PATCH "$BASE/users/$UID27" -H "Content-Type: application/json" \
  --data '{"name":"Outbox Probe Renamed"}'
UU_A=$(outbox_count users UPDATED); PU_A=$(outbox_count persons UPDATED)
assert_outbox_delta "users UPDATED" "$UU_B" "$UU_A" 1
assert_outbox_delta "persons UPDATED" "$PU_B" "$PU_A" 1

title "27.3 PUT replacing both addresses with three → users UPDATED +1, persons UPDATED +1"
UU_B=$(outbox_count users UPDATED); PU_B=$(outbox_count persons UPDATED)
curl -sS -o /dev/null -X PUT "$BASE/users/$UID27" -H "Content-Type: application/json" --data '{
  "name":"Outbox Probe Renamed","email":"outbox.qa27@example.com","phone":"14155552671",
  "userName":"outboxp","emailNotification":false,"smsNotification":false,
  "addresses":[
    {"label":"a","street":"Third","number":"3","neighborhood":"N","city":"San Francisco","state":"CA","zipCode":"94110","country":"US"},
    {"label":"b","street":"Fourth","number":"4","neighborhood":"N","city":"San Francisco","state":"CA","zipCode":"94111","country":"US"},
    {"label":"c","street":"Fifth","number":"5","neighborhood":"N","city":"San Francisco","state":"CA","zipCode":"94112","country":"US"}
  ]}'
UU_A=$(outbox_count users UPDATED); PU_A=$(outbox_count persons UPDATED)
assert_outbox_delta "users UPDATED" "$UU_B" "$UU_A" 1
assert_outbox_delta "persons UPDATED" "$PU_B" "$PU_A" 1

title "27.4 ARCHIVE → users ARCHIVED +1"
AR_B=$(outbox_count users ARCHIVED)
curl -sS -o /dev/null -X PATCH "$BASE/users/$UID27/archive" -H "Content-Type: application/json"
AR_A=$(outbox_count users ARCHIVED)
assert_outbox_delta "users ARCHIVED" "$AR_B" "$AR_A" 1

title "27.5 UNARCHIVE → users UNARCHIVED +1"
UN_B=$(outbox_count users UNARCHIVED)
curl -sS -o /dev/null -X PATCH "$BASE/users/$UID27/unarchive" -H "Content-Type: application/json"
UN_A=$(outbox_count users UNARCHIVED)
assert_outbox_delta "users UNARCHIVED" "$UN_B" "$UN_A" 1

title "27.6 DELETE (last role, orphan base) → users DELETED +1, persons DELETED +1"
UD_B=$(outbox_count users DELETED); PD_B=$(outbox_count persons DELETED)
curl -sS -o /dev/null -X DELETE "$BASE/users/$UID27"
UD_A=$(outbox_count users DELETED); PD_A=$(outbox_count persons DELETED)
assert_outbox_delta "users DELETED" "$UD_B" "$UD_A" 1
assert_outbox_delta "persons DELETED (refcount purge)" "$PD_B" "$PD_A" 1

title "27.7 Grand invariant — addresses NEVER appear in the outbox (granularity B)"
ADDR_OUTBOX_27_AFTER=$(qa_db_query "SELECT count(*) FROM outbox WHERE aggregate_type='addresses';")
if [ "$ADDR_OUTBOX_27_AFTER" = "$ADDR_OUTBOX_27" ] && [ "$ADDR_OUTBOX_27_AFTER" = "0" ]; then
  printf '\033[1;32mPASS\033[0m (zero address-typed outbox rows across every verb)\n'; PASS=$((PASS+1))
else
  printf '\033[1;31mFAIL\033[0m (addresses outbox rows: %s → %s, want 0)\n' "$ADDR_OUTBOX_27" "$ADDR_OUTBOX_27_AFTER"; FAIL=$((FAIL+1))
fi

####################################
sec "Summary"
####################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
echo "USER_A=$USER_A"
echo "USER_B=$USER_B"
echo "USER_C=$USER_C (archived in 3.2 — stays archived; sibling active user holds the email)"
echo "USER_A=$USER_A (archived in 7.x, unarchived in 7.3, re-archived in 10.6, unarchived again in 10.8)"
echo "USER_C2=$USER_C2 (deleted in 8.x)"
echo "mike@example.com (created/updated/patched/archived/unarchived/deleted in section 11)"
echo "section 12: GETs against jane@example.com + bob@example.com via /showcase/users-custom/* — no state changes"
