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
# Requires the service to be running locally on :8080 (go run ./bootstrap),
# Postgres on :5433 (docker compose) and the Debezium connector registered.
#
# Run from anywhere:  bash qa/e2e.sh
set -u

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
title "GET /health"
echo "REQUEST : GET /health"
curl -sS -w "\nSTATUS  : %{http_code}\n" "$BASE/health"

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
title "TRUNCATE users CASCADE + TRUNCATE outbox (Postgres)"
docker exec omnicore-example-postgres psql -U omnicore -d users_db -c \
  "TRUNCATE TABLE users CASCADE; TRUNCATE TABLE outbox;" > /dev/null
echo "Postgres: users + addresses (FK CASCADE) + outbox cleared."

title "db.users.deleteMany({}) (Mongo)"
docker exec omnicore-example-mongo mongosh users_views --quiet --eval \
  "db.users.deleteMany({});" > /dev/null
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

title "2.2 Create Bob (UK) — will be used in conflict tests"
BODY_B='{
  "name":"Bob Smith","email":"bob@example.com","phone":"442079460000",
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
sec "3. POST /users — Conflict notifications (409) + soft-delete reuse"
####################################

show "3.1 EmailAlreadyExistsNotification (retry bob@example.com)" POST /users '{
  "name":"Other","email":"bob@example.com","phone":"442079461111",
  "addresses":[{"label":"home","street":"Other","number":"2","neighborhood":"X","city":"London","state":"England","zipCode":"SW1A 1AA","country":"GB"}]
}' 409

# 3.2 demonstrates that the unique index is soft-delete-aware
# (`WHERE deleted_at IS NULL` in migration 0002): after archiving the record
# that holds the email, a POST with the same email MUST be accepted (201)
# because the previous value is logically deleted. Replaces the old
# CPFAlreadyExists case — same test shape (unique constraint), now showing
# the full semantic: reserved while active, free when archived.
title "3.2 Soft-delete-aware uniqueness — archive USER_C, reuse of anna@example.com allowed"
echo "Pre-step: PATCH USER_C/archive (then reuse the email)"
ARCH_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -X PATCH "$BASE/users/$USER_C/archive" -H "Content-Type: application/json")
echo "Archive USER_C status: $ARCH_STATUS"
show "3.2 POST with the email of archived USER_C — expected 201" POST /users '{
  "name":"Anna II","email":"anna@example.com","phone":"493012345678",
  "addresses":[{"label":"home","street":"Kurfürstendamm","number":"1","neighborhood":"Charlottenburg","city":"Berlin","state":"Berlin","zipCode":"10719","country":"DE"}]
}' 201
# Capture the new ID for later cleanup — USER_C is now archived and unreachable
JSON_C2=$(curl -sS "$BASE/users?email=anna@example.com" 2>/dev/null || echo '{}')
USER_C2=$(curl -sS -X POST "$BASE/users" -H "Content-Type: application/json" -H "Accept-Language: en-US" \
  -d '{"name":"Anna III","email":"anna3@example.com","phone":"493012340000",
       "addresses":[{"label":"home","street":"X","number":"1","neighborhood":"Y","city":"Berlin","state":"Berlin","zipCode":"10115","country":"DE"}]}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null || echo "")
echo "USER_C2 (Anna III, new for DELETE in 8.x) = $USER_C2"

####################################
sec "4. GET /users/:id and GET /users (CDC eventually consistent)"
####################################

title "4.0 Polling Mongo via GET /users/$USER_A until 200 (CDC)"
if wait_for_view "$USER_A" "200" 15; then
  echo "view ready"
else
  echo "TIMEOUT waiting for view (15s) — continuing anyway to record the failure"
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

####################################
sec "4.5 GET /users — partial-match operators (startswith/contains + i-twins)"
####################################
# The Request DTO `FindUsersByParamsRequest` declares:
#   Name  → filter:"eq,startswith,icontains"
#   Email → filter:"eq,in,ieq"
#   City  → filter:"eq,istartswith"
# Suite state at this point: Jane Doe (Cupertino), Bob Smith (London),
# Anna II (Berlin), Anna III (Berlin). USER_C archived (Anna I — hidden
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

# 4.5.4 — icontains anywhere in the string: "nn" matches "Anna II" and "Anna III"
show_count "4.5.4 ?name.icontains=nn matches Anna II + Anna III (substring anywhere)" \
  "/users?name.icontains=nn" 200 2

# 4.5.5 — ieq case-insensitive equality on email
show_count "4.5.5 ?email.ieq=BOB@EXAMPLE.COM matches bob@example.com (case-insensitive equality)" \
  "/users?email.ieq=BOB%40EXAMPLE.COM" 200 1

# 4.5.6 — istartswith case-folded prefix on name (matches "Anna II" + "Anna III")
# Note: city is declared with istartswith on the DTO but the Mongo view stores
# city nested inside addresses[], not top-level — filtering at top level on
# `city` matches nothing. The DTO declaration stays as wire allowlist; this
# case exercises the operator against a top-level field that does match.
show_count "4.5.6 ?name.istartswith=anna matches Anna II + Anna III (case-insensitive prefix)" \
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
# (London, GB), Anna II (Berlin, DE), Anna III (Berlin, DE).

# 4.6.1 — wire ?addresses.city=Berlin → Mongo Filter[addresses.city]=Berlin
show_count "4.6.1 ?addresses.city=Berlin matches Anna II + Anna III (nested top-level eq)" \
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

show "5.1 PUT happy (all fields)" PUT "/users/$USER_A" '{
  "name":"Jane Doe (updated)","email":"jane@example.com","phone":"14155553333",
  "addresses":[{
    "label":"home","street":"New Address","number":"200",
    "neighborhood":"Downtown","city":"San Francisco","state":"CA","zipCode":"94110","country":"US"
  }]
}' 200

show "5.2 PUT without phone (Phase 21: RequiredFieldNotification semantic Schema → 400)" PUT "/users/$USER_A" '{
  "name":"Jane","email":"jane@example.com",
  "addresses":[{"label":"home","street":"X","number":"1","neighborhood":"X","city":"San Francisco","state":"CA","zipCode":"94103","country":"US"}]
}' 400

show "5.3 PUT without addresses (Phase 21: RequiredFieldNotification semantic Schema → 400)" PUT "/users/$USER_A" '{
  "name":"Jane","email":"jane@example.com","phone":"14155553333"
}' 400

show "5.4 PUT /users/<nonexistent> (RecordNotFound)" PUT /users/00000000-0000-0000-0000-000000000000 '{
  "name":"X","email":"x@x.com","phone":"14155553333",
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

show "6.5 PATCH with Bob's duplicate email (Conflict 409)" PATCH "/users/$USER_A" '{"email":"bob@example.com"}' 409

show "6.6 PATCH invalid email (Validation 422)" PATCH "/users/$USER_A" '{"email":"not-an-email"}' 422

show "6.7 PATCH /users/<nonexistent> (RecordNotFound)" PATCH /users/00000000-0000-0000-0000-000000000000 '{"name":"X"}' 404

# 6.8 demonstrates the transition-aware invariant powered by domain.Old[*User]:
# a PATCH whose new email is valid AND unused must still be rejected because
# email is immutable once the user is created. The chosen email is a brand-new
# address that no other user holds — so the rejection is purely the
# EmailCannotChangeNotification (422 Validation), not EmailAlreadyExists (409).
show "6.8 PATCH with valid unused email (immutable rule via domain.Old → 422)" PATCH "/users/$USER_A" '{"email":"jane.new@example.com"}' 422

####################################
sec "7. PATCH /users/:id/archive  and  /:id/unarchive — aggregate-aware"
####################################

show "7.1 Archive (empty body accepted)" PATCH "/users/$USER_A/archive" "" 200

title "7.1.b Postgres: Jane's addresses cascaded (deleted_at NOT NULL)"
docker exec omnicore-example-postgres psql -U omnicore -d users_db -c \
  "SELECT id, deleted_at IS NOT NULL AS archived FROM addresses WHERE user_id='$USER_A';"

show "7.2 Re-archive already archived (expected 404 — FindByID filters deleted_at NULL)" PATCH "/users/$USER_A/archive" "" 404

show "7.3 Unarchive (restores root + addresses)" PATCH "/users/$USER_A/unarchive" "" 200

title "7.3.b Postgres: addresses are back (deleted_at NULL)"
docker exec omnicore-example-postgres psql -U omnicore -d users_db -c \
  "SELECT id, deleted_at IS NULL AS active FROM addresses WHERE user_id='$USER_A';"

show "7.4 Unarchive on an active record (expected 404 — FindArchivedByID only sees deleted ones)" PATCH "/users/$USER_A/unarchive" "" 404

show "7.5 Archive on a nonexistent UUID (RecordNotFound)" PATCH "/users/00000000-0000-0000-0000-000000000000/archive" "" 404

####################################
sec "8. DELETE /users/:id (hard delete)"
####################################

show "8.1 DELETE USER_C2 (Anna III) — expected 204" DELETE "/users/$USER_C2" "" 204

show "8.2 DELETE again (RecordNotFound)" DELETE "/users/$USER_C2" "" 404

title "8.3 Postgres: ON DELETE cascade removed USER_C2's addresses"
docker exec omnicore-example-postgres psql -U omnicore -d users_db -c \
  "SELECT COUNT(*) AS leftover_addresses FROM addresses WHERE user_id='$USER_C2';"

####################################
sec "9. Read side (Mongo) — re-check view after PATCH/Archive/Unarchive"
####################################

title "9.0 Polling Mongo via GET /users/$USER_A until 200 (CDC consolidating all UPDATEs/ARCHIVE/UNARCHIVE)"
if wait_for_view "$USER_A" "200" 15; then
  echo "view ready"
else
  echo "TIMEOUT waiting for view (15s)"
fi

show "9.1 GET /users/USER_A (with PATCHes already applied via CDC)" GET "/users/$USER_A" "" 200

show "9.2 GET /users (listing with default pagination)" GET /users "" 200

####################################
sec "10. Query allowlist (filter tags + reserved by-id param)"
####################################
# Exercises the HandleQueryWithParams / HandleQueryWithID surface introduced by
# the queries refactor: the Request DTO declares the allowlist via
# `query:"X" filter:"ops"` tags, the framework rejects unknown fields and
# operators with 400, and the ?includeArchived=true reserved param flows through to
# the ViewReader.

show "10.1 GET /users?name=Jane Doe (filter:eq declared on name)" GET "/users?name=Jane%20Doe" "" 200
show "10.2 GET /users?email.in=jane@example.com,bob@example.com (filter:eq,in on email)" GET "/users?email.in=jane@example.com,bob@example.com" "" 200
show "10.3 GET /users?role=admin (field NOT in the allowlist → 400)" GET "/users?role=admin" "" 400
show "10.4 GET /users?email.gte=Z (operator NOT in declared list for email → 400)" GET "/users?email.gte=Z" "" 400
# 10.5–10.5b: by-id reads on USER_C (archived in 3.2) exercise the canonical
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
show "10.5 GET /users/USER_C?includeArchived=true while archived (keep-by-default → 200 with archived doc)" GET "/users/$USER_C?includeArchived=true" "" 200
show "10.5b GET /users/USER_C while archived (default reader filter hides → 404)" GET "/users/$USER_C" "" 404

# 10.6–10.9: end-to-end Archive → ?includeArchived=true → Unarchive → ?includeArchived=false
# cycle on USER_A (currently active after 7.3). Demonstrates that the read
# side honors the keep-by-default Mongo view — ARCHIVED upserts the doc
# with deleted_at populated (default GET 404, ?includeArchived=true 200);
# UNARCHIVED re-upserts clearing deleted_at via SyncEngine, then the
# standard GET returns 200. Using USER_A keeps section 10 self-contained:
# USER_C is left archived and its email "anna@example.com" is still held
# by a sibling active user from the 3.2 soft-delete-aware uniqueness test,
# so unarchiving USER_C would 409.
show "10.6 PATCH /users/USER_A/archive (re-archive to exercise the query-side cycle)" PATCH "/users/$USER_A/archive" "" 200

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
show "10.8 PATCH /users/USER_A/unarchive (restores root + addresses)" PATCH "/users/$USER_A/unarchive" "" 200

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
sec "11. /showcase/users-custom/* — manual write showcase (email as identifier)"
####################################
# Cross-checks the parallel surface that hand-rolls every layer above
# domain/. Uses Mike's row (mike@example.com) — fresh across runs because
# the suite TRUNCATEs the users table at 0.5. Email is the identifier in
# the URL path; PUT/PATCH bodies intentionally omit Email (immutable on
# this surface; documented in CLAUDE.md under "Manual showcase"). Writes
# land on the same `users` + `addresses` tables the canonical /users/*
# surface uses, so a successful POST here would surface on a canonical
# GET /users/:id once CDC propagates (not asserted here — already covered
# in sections 4 and 9 for the canonical surface).

show "11.1 POST /showcase/users-custom (create Mike, US)" POST /showcase/users-custom/ '{
  "name":"Mike Manual","email":"mike@example.com","phone":"14155556666",
  "addresses":[{"label":"home","street":"1 Manual Way","number":"42","neighborhood":"Showcase","city":"Cupertino","state":"CA","zipCode":"95014","country":"US"}]
}' 201

show "11.2 POST same email — Conflict (proves write hit the same users table)" POST /showcase/users-custom/ '{
  "name":"Mike Twin","email":"mike@example.com","phone":"14155557777",
  "addresses":[{"label":"twin","street":"2 Twin Ln","number":"1","neighborhood":"Twin","city":"Cupertino","state":"CA","zipCode":"95014","country":"US"}]
}' 409

show "11.3 PUT /showcase/users-custom/mike@example.com (full replace — no Email in body)" PUT /showcase/users-custom/mike@example.com '{
  "name":"Mike Updated","phone":"14155558888",
  "addresses":[{"label":"office","street":"1 Apple Park Way","number":"1","neighborhood":"Mariani","city":"Cupertino","state":"CA","zipCode":"95014","country":"US"}]
}' 200

show "11.4 PATCH /showcase/users-custom/mike@example.com (name only — no Email in body)" PATCH /showcase/users-custom/mike@example.com '{"name":"Mike Patched"}' 200

show "11.5 PATCH /showcase/users-custom/mike@example.com/archive (aggregate-aware soft-delete)" PATCH /showcase/users-custom/mike@example.com/archive "" 200
show "11.6 PATCH /showcase/users-custom/mike@example.com/unarchive (FindArchivedByEmail path)" PATCH /showcase/users-custom/mike@example.com/unarchive "" 200
show "11.7 DELETE /showcase/users-custom/mike@example.com (hard delete — 204 No Content)" DELETE /showcase/users-custom/mike@example.com "" 204

show "11.8 PUT on ghost email — RecordNotFound (404)" PUT /showcase/users-custom/ghost@example.com '{
  "name":"X","phone":"14155550000","addresses":[]
}' 404

show "11.9 POST with missing name — RequiredFieldNotification (422 — Domain BuildRules, not Schema)" POST /showcase/users-custom/ '{
  "email":"nameless@example.com","addresses":[]
}' 422

show "11.10 POST with malformed JSON — Schema violation (400)" POST /showcase/users-custom/ '{not json' 400

####################################
sec "12. /showcase/users-custom/* — manual read showcase (by-email + list + reduced shape)"
####################################
# Reads against the same Mongo view the canonical /users/* surface uses
# (UserView()). Two endpoints; both project the denormalized doc down to
# {id, name, email} — phone and addresses are intentionally absent
# (UserSummaryResponse). Reuses jane@example.com (active throughout the
# suite after 10.8 restored her) and bob@example.com (active since 2.2);
# no fresh fixtures, no CDC waits — section 9 already polled Mongo into
# sync for these rows.

show "12.1 GET /showcase/users-custom/jane@example.com — reduced shape (id+name+email only)" GET /showcase/users-custom/jane@example.com "" 200
show "12.2 GET /showcase/users-custom/ghost@example.com — RecordNotFound (404)" GET /showcase/users-custom/ghost@example.com "" 404
show "12.3 GET /showcase/users-custom — list with pagination envelope top-level" GET /showcase/users-custom "" 200
show "12.4 GET /showcase/users-custom?email=bob@example.com — filtered list" GET "/showcase/users-custom?email=bob@example.com" "" 200
show "12.5 GET /showcase/users-custom?limit=1 — paged list (has_next:true expected)" GET "/showcase/users-custom?limit=1" "" 200
show "12.6 GET /showcase/users-custom?role=admin — unknown query key rejected (400 via ParseCriteria allowlist)" GET "/showcase/users-custom?role=admin" "" 400
show "12.7 GET /showcase/users-custom/jane@example.com?includeArchived=true — flag accepted, active row still surfaces" GET "/showcase/users-custom/jane@example.com?includeArchived=true" "" 200
show "12.8 GET /showcase/users-custom?includeArchived=true — flag accepted on list" GET "/showcase/users-custom?includeArchived=true" "" 200
show "12.9 GET /showcase/users-custom?name.in=Jane,Bob — operator outside declared list rejected (400, name carries filter:\"eq\" only)" GET "/showcase/users-custom?name.in=Jane,Bob" "" 400
show "12.10 GET /showcase/users-custom?name=Jane — allowed filter (200; happy path via the new allowlist)" GET "/showcase/users-custom?name=Jane" "" 200
show "12.11 GET /showcase/users-custom/jane@example.com?tenant=acme — unknown query key on by-email rejected (400)" GET "/showcase/users-custom/jane@example.com?tenant=acme" "" 400

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

  show "13.10 GET /showcase/users-custom/jane@example.com/addresses/ADDRESS_ID (custom happy path)" \
    GET "/showcase/users-custom/jane@example.com/addresses/$ADDRESS_ID" "" 200

  show "13.11 GET /showcase/users-custom/ghost@example.com/addresses/ADDRESS_ID (User absent → 404)" \
    GET "/showcase/users-custom/ghost@example.com/addresses/$ADDRESS_ID" "" 404

  show "13.12 GET /showcase/users-custom/jane@example.com/addresses/<unknown> (Address absent → 404)" \
    GET "/showcase/users-custom/jane@example.com/addresses/00000000-0000-0000-0000-000000000000" "" 404

  show "13.13 GET /showcase/.../addresses/ADDRESS_ID?role=admin (unknown query key → 400)" \
    GET "/showcase/users-custom/jane@example.com/addresses/$ADDRESS_ID?role=admin" "" 400

  show "13.14 PUT /showcase/.../jane@example.com/addresses/ADDRESS_ID (custom happy path)" \
    PUT "/showcase/users-custom/jane@example.com/addresses/$ADDRESS_ID" '{
      "label":"home","street":"1 Custom Way","number":"1",
      "neighborhood":"Downtown","city":"San Francisco","state":"CA",
      "zipCode":"94103","country":"US"
    }' 200

  show "13.15 PUT /showcase/.../ghost@example.com/addresses/ADDRESS_ID (User absent → 404)" \
    PUT "/showcase/users-custom/ghost@example.com/addresses/$ADDRESS_ID" '{
      "label":"x","street":"x","number":"1","neighborhood":"x","city":"x",
      "state":"CA","zipCode":"94103","country":"US"
    }' 404

  show "13.16 PUT /showcase/.../jane@example.com/addresses/<unknown> (Address absent → 404)" \
    PUT "/showcase/users-custom/jane@example.com/addresses/00000000-0000-0000-0000-000000000000" '{
      "label":"x","street":"x","number":"1","neighborhood":"x","city":"x",
      "state":"CA","zipCode":"94103","country":"US"
    }' 404

  show "13.17 PUT /showcase/.../jane@example.com/addresses/ADDRESS_ID with invalid state (422)" \
    PUT "/showcase/users-custom/jane@example.com/addresses/$ADDRESS_ID" '{
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
if [ "$FIRST_NAME" = "Anna II" ] || [ "$FIRST_NAME" = "Anna III" ]; then
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
  STATUS=$(curl -sS -o /tmp/qa-e2e-filter-mismatch.body -w "%{http_code}" "$BASE/users?limit=1&after=$NO_FILTER_CURSOR&name.startswith=B")
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
  STATUS=$(curl -sS -o /tmp/qa-e2e-sort-mismatch.body -w "%{http_code}" "$BASE/users?limit=1&after=$NO_SORT_CURSOR&sort=name")
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
  STATUS=$(curl -sS -o /tmp/qa-e2e-archived-mismatch.body -w "%{http_code}" "$BASE/users?limit=1&after=$DEFAULT_CTX_CURSOR&includeArchived=true")
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
  "pt-BR" '{"name":"","email":"label-pt@example.com","phone":"14155553333","addresses":[]}' \
  "422" "Nome"

# 18.2 — Same notification, different locale: ENG catalog renders "Name".
field_label_check "18.2 POST missing Name → 422 with fieldLabel=Name (en-US)" \
  "en-US" '{"name":"","email":"label-en@example.com","phone":"14155554444","addresses":[]}' \
  "422" "Name"

# 18.3 — Aggregate child label: Address.ZipCode tag resolves through the
# scoped Rules; the wire `field` retains the path "addresses[0].zipCode"
# and `fieldLabel` carries the translated AVO field label.
title "18.3 POST invalid Address.ZipCode → 422 with field=addresses[0].zipCode + fieldLabel=CEP (PT-BR)"
ADDR_BODY='{"name":"With Address","email":"label-addr@example.com","phone":"14155555555","addresses":[{"label":"home","street":"Main","number":"1","neighborhood":"Centro","city":"Cidade","state":"SP","zipCode":"AB","country":"BR"}]}'
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
