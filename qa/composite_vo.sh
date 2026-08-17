#!/usr/bin/env bash
# Composite value objects — a value object whose value spans several persisted
# columns. Exercised through the qa-only Contract aggregate (`//go:build qa`),
# which packs every branch of the design into one flat root:
#
#   Code    ContractCode  — a SCALAR value object (one column), the contrast
#   Salary  Money         — a MANDATORY composite, with an ENUM value-object part
#   Trial   *Period       — an OPTIONAL composite, one mandatory + one nullable
#                           part, and a CROSS-FIELD rule
#
# The suite asserts the three things the design promises, and it asserts them on
# BOTH read backings — the Mongo projection (/qa/contracts) and the
# RelationalSource twin (/qa/contracts-rel), which reach the document by
# different code paths:
#
#   1. STORAGE — five columns, checked directly in the SoR and in the Mongo
#      document, which must carry FLAT PHYSICAL COLUMNS with no trace of a
#      composite (the transparency posture, asserted rather than assumed).
#   2. RECONSTRUCTION — the four-row absence matrix, including the corrupt
#      half-written row planted by direct SQL, and the enum part's convergence.
#   3. THE DOMAIN — the composite's own rules fire with nothing declared, the
#      Old() ghost carries the value object, and the audit delta is PER PART with
#      the label coming from the tag inside the value object.
#
# Self-managed; qa binary (-tags '<engine> qa') + microservice.qa.yaml.
# Dialect-driven via qa/_backend.sh.  Run from anywhere:  bash qa/composite_vo.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-composite-vo-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-composite-vo-${BACKEND:-postgres}.log"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port "${HTTP_PORT:-8080}"
  qa_view_drop qa_contracts_view
}
trap cleanup EXIT INT TERM

# jsonf <json> <python-expr> — read a field out of a JSON body with python3.
jsonf() { printf '%s' "$1" | python3 -c "import sys,json;d=json.load(sys.stdin);print($2)" 2>/dev/null; }

# expect_status <label> <want> <method> <path> [body]
expect_status() {
  local label="$1" want="$2" method="$3" path="$4" body="${5:-}" code
  if [ -n "$body" ]; then
    code=$(curl -sSg -o /tmp/cv_body.$$ -w '%{http_code}' -X "$method" "$BASE$path" -H "Content-Type: application/json" --data "$body")
  else
    code=$(curl -sSg -o /tmp/cv_body.$$ -w '%{http_code}' -X "$method" "$BASE$path")
  fi
  LAST_BODY=$(cat /tmp/cv_body.$$ 2>/dev/null); rm -f /tmp/cv_body.$$
  [ "$code" = "$want" ] && ok "$label ($code)" || { bad "$label — want $want, got $code"; printf '%s\n' "$LAST_BODY" | head -c 600; echo; }
}

# notified <label> <notification-key> — the last body carries this notification.
notified() {
  if printf '%s' "$LAST_BODY" | grep -q "\"$2\""; then ok "$1"; else bad "$1 — $2 absent"; printf '%s\n' "$LAST_BODY" | head -c 600; echo; fi
}

##############################################################################
sec "0. Build qa binary + boot + clean baseline"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"

title "0.2 Start server (APP_PROFILE=dev, config=microservice.qa.yaml)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$REPO_ROOT/microservice.qa.yaml" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready (PID=$SERVER_PID)" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }

title "0.3 Reset qa_contracts + its audit trail"
qa_db_exec "DELETE FROM audit_events WHERE entity_type='Contract';"
qa_db_exec "DELETE FROM qa_contracts;"
qa_view_clear qa_contracts_view
ok "clean contract baseline"

##############################################################################
sec "1. Storage — one value object, several columns"
##############################################################################
title "1.1 POST /qa/contracts with BOTH composites → 201"
expect_status "insert with a trial period" 201 POST /qa/contracts \
  '{"code":"CT-9911","salaryAmount":850000,"salaryCurrency":"BRL","trialFrom":"2026-01-06T00:00:00Z"}'
CT_ID=$(jsonf "$LAST_BODY" 'd["data"]["id"]')
[ -n "$CT_ID" ] && ok "id=$CT_ID" || bad "no id in the write response"

title "1.2 The SoR carries five columns, not two value objects"
ROW=$(qa_db_query "SELECT code, salary_amount, salary_currency FROM qa_contracts WHERE code='CT-9911'" | tr -d '\r')
echo "$ROW" | grep -q "CT-9911" && echo "$ROW" | grep -q "850000" && echo "$ROW" | grep -q "BRL" \
  && ok "salary_amount + salary_currency stored as their own columns" \
  || bad "unexpected row: $ROW"
# The enum part is stored as its UNDERLYING string, never the named Go type.
[ "$(qa_db_query "SELECT COUNT(*) FROM qa_contracts WHERE salary_currency='BRL'" | tr -d '[:space:]')" = "1" ] \
  && ok "the enum part persisted as its underlying scalar" || bad "enum part not stored as its underlying"

title "1.3 An ABSENT optional composite writes NULL to EVERY one of its columns"
expect_status "insert with no trial period" 201 POST /qa/contracts \
  '{"code":"CT-NOTRIAL","salaryAmount":100,"salaryCurrency":"USD"}'
NOTRIAL_ID=$(jsonf "$LAST_BODY" 'd["data"]["id"]')
NULLS=$(qa_db_query "SELECT COUNT(*) FROM qa_contracts WHERE code='CT-NOTRIAL' AND trial_from IS NULL AND trial_to IS NULL" | tr -d '[:space:]')
[ "$NULLS" = "1" ] && ok "nil *Period ⇒ every part column NULL" || bad "absent composite did not null every part column"

##############################################################################
sec "2. Reconstruction — the absence matrix, on BOTH read backings"
##############################################################################
title "2.1 Relational twin reads back both composites (read-your-writes)"
expect_status "GET /qa/contracts-rel/:id" 200 GET "/qa/contracts-rel/$CT_ID"
REL_AMOUNT=$(jsonf "$LAST_BODY" 'd["data"]["salaryAmount"]')
REL_CUR=$(jsonf "$LAST_BODY" 'd["data"]["salaryCurrency"]')
REL_FROM=$(jsonf "$LAST_BODY" 'd["data"].get("trialFrom","")')
[ "$REL_AMOUNT" = "850000" ] && [ "$REL_CUR" = "BRL" ] && [ -n "$REL_FROM" ] \
  && ok "the mandatory composite and the present optional one both reconstruct" \
  || bad "relational read = amount:$REL_AMOUNT currency:$REL_CUR from:$REL_FROM"

title "2.2 An absent optional composite reconstructs as absent, not as zeros"
expect_status "GET the trial-less contract" 200 GET "/qa/contracts-rel/$NOTRIAL_ID"
HAS_FROM=$(jsonf "$LAST_BODY" '"yes" if d["data"].get("trialFrom") else "no"')
[ "$HAS_FROM" = "no" ] && ok "every part NULL ⇒ the value object is absent" || bad "an absent composite came back materialized"

title "2.3 Wait for the Mongo projection, then read the SAME contract from it"
# The active collection is re-resolved on EVERY iteration: dropping the view in
# a previous run's cleanup makes this boot detect drift and rebuild, which FLIPS
# the blue-green slot (__0 ⇄ __1) while this loop is running. Resolving once,
# up front, would poll the retired slot forever.
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); landed=no
while [ "$(date +%s)" -lt "$deadline" ]; do
  mcoll=$(qa_view_coll qa_contracts_view)
  n=$(docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval \
    "db.getCollection('$mcoll').countDocuments({code:'CT-9911'})" 2>/dev/null | tr -d '[:space:]')
  [ "$n" = "1" ] && { landed=yes; break; }
  sleep 1
done
if [ "$landed" = yes ]; then
  ok "the contract projected into $mcoll"
  expect_status "GET /qa/contracts/:id (Mongo backing)" 200 GET "/qa/contracts/$CT_ID"
  M_AMOUNT=$(jsonf "$LAST_BODY" 'd["data"]["salaryAmount"]')
  M_CUR=$(jsonf "$LAST_BODY" 'd["data"]["salaryCurrency"]')
  [ "$M_AMOUNT" = "$REL_AMOUNT" ] && [ "$M_CUR" = "$REL_CUR" ] \
    && ok "both backings agree field for field" \
    || bad "backings diverge — mongo:$M_AMOUNT/$M_CUR relational:$REL_AMOUNT/$REL_CUR"

  title "2.4 The Mongo document stores FLAT PHYSICAL COLUMNS — no composite"
  DOC=$(docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval \
    "JSON.stringify(db.getCollection('$mcoll').findOne({code:'CT-9911'}))" 2>/dev/null)
  echo "$DOC" | grep -q '"salary_amount"' && echo "$DOC" | grep -q '"salary_currency"' && echo "$DOC" | grep -q '"trial_from"' \
    && ok "the document carries the part columns flat" || { bad "document is missing the flat part columns"; echo "$DOC" | head -c 500; }
  if echo "$DOC" | grep -qE '"(salary|trial)"[[:space:]]*:'; then
    bad "the document carries a nested composite — the projection must not know one exists"
  else
    ok "no nested salary/trial object — the composite evaporated in the schema"
  fi
else
  bad "the contract never reached the Mongo projection within ${QA_CDC_DEADLINE}s"
fi

title "2.5 A HALF-WRITTEN optional composite is a loud error, never silent zeros"
# Write both ends through the API, then NULL the MANDATORY part in the SoR: the
# value object is present (its nullable part carries a value) but incomplete.
expect_status "insert a contract with a full trial period" 201 POST /qa/contracts \
  '{"code":"CT-HALF","salaryAmount":7,"salaryCurrency":"USD","trialFrom":"2026-01-06T00:00:00Z","trialTo":"2026-04-06T00:00:00Z"}'
HALF_ID=$(jsonf "$LAST_BODY" 'd["data"]["id"]')
qa_db_exec "UPDATE qa_contracts SET trial_from = NULL WHERE code='CT-HALF';"
CODE=$(curl -sSg -o /tmp/cv_half.$$ -w '%{http_code}' "$BASE/qa/contracts-rel/$HALF_ID")
if [ "$CODE" = "200" ]; then
  bad "a row with a NULL mandatory part and a set nullable one must not read as valid"
  head -c 400 /tmp/cv_half.$$; echo
else
  ok "half-written composite refused ($CODE)"
fi
rm -f /tmp/cv_half.$$
qa_db_exec "DELETE FROM qa_contracts WHERE code='CT-HALF';"

title "2.6 An out-of-set enum part converges to Unknown on read"
qa_db_exec "UPDATE qa_contracts SET salary_currency='XYZ' WHERE code='CT-NOTRIAL';"
expect_status "GET the tampered contract" 200 GET "/qa/contracts-rel/$NOTRIAL_ID"
CONV=$(jsonf "$LAST_BODY" 'd["data"].get("salaryCurrency","")')
[ -z "$CONV" ] && ok "a value outside the declared set reconstructs as Unknown, never a phantom member" \
  || bad "salaryCurrency = '$CONV', want the Unknown sentinel"
qa_db_exec "UPDATE qa_contracts SET salary_currency='USD' WHERE code='CT-NOTRIAL';"

##############################################################################
sec "3. The domain — rules the composite owns, with nothing declared"
##############################################################################
title "3.1 The CROSS-FIELD rule fires (To before From)"
expect_status "trial ending before it starts" 422 POST /qa/contracts \
  '{"code":"CT-BAD","salaryAmount":1,"salaryCurrency":"BRL","trialFrom":"2026-06-01T00:00:00Z","trialTo":"2026-01-01T00:00:00Z"}'
notified "PeriodEndsBeforeStartNotification emitted by the value object itself" "PeriodEndsBeforeStartNotification"

title "3.2 A part-level rule fires and carries the value object's label"
expect_status "negative amount" 422 POST /qa/contracts \
  '{"code":"CT-NEG","salaryAmount":-5,"salaryCurrency":"BRL"}'
notified "NegativeAmountNotification" "NegativeAmountNotification"
if printf '%s' "$LAST_BODY" | grep -q "MoneyAmountField"; then
  ok "the notification's label comes from the tag INSIDE the value object"
else
  bad "no MoneyAmountField label — a part-level notification lost its label"
  printf '%s\n' "$LAST_BODY" | head -c 600; echo
fi

title "3.3 The enum part's membership is validated by the framework"
expect_status "unknown currency" 422 POST /qa/contracts \
  '{"code":"CT-CUR","salaryAmount":1,"salaryCurrency":"XYZ"}'
notified "UnknownCurrencyNotification" "UnknownCurrencyNotification"

title "3.4 An absent optional composite is never a violation"
expect_status "insert with no trial at all" 201 POST /qa/contracts \
  '{"code":"CT-OK","salaryAmount":42,"salaryCurrency":"EUR"}'

title "3.5 A transition rule reads the composite off the Old() ghost"
expect_status "changing the currency" 422 PUT "/qa/contracts/$CT_ID" \
  '{"code":"CT-9911","salaryAmount":850000,"salaryCurrency":"USD","trialFrom":"2026-01-06T00:00:00Z","trialTo":null}'
notified "CurrencyIsImmutableNotification (the ghost carried the value object)" "CurrencyIsImmutableNotification"

##############################################################################
sec "4. Audit — one entry per PART, delta per part"
##############################################################################
title "4.1 The insert snapshot carries each part under its EXPOSED name"
# The payload is asked about with a LIKE predicate rather than pulled out and
# grepped: it is a CLOB on some engines, and a client-side render truncates it
# (sqlplus caps LONG output at 80 chars by default), which would silently drop
# whichever key sorts last and read as a framework failure.
# The payload column's type differs per engine (jsonb / json / nvarchar / clob),
# and only some of them accept LIKE directly — Postgres needs the text cast.
case "${BACKEND:-postgres}" in
  postgres) AUDIT_PAYLOAD="payload::text" ;;
  *)        AUDIT_PAYLOAD="payload" ;;
esac
audit_has() { # audit_has <verb> <fragment> -> "1" when present
  qa_db_query "SELECT COUNT(*) FROM audit_events WHERE entity_type='Contract' AND verb='$1' AND aggregate_id='$CT_ID' AND $AUDIT_PAYLOAD LIKE '%$2%'" | tr -d '[:space:]' | tail -1
}
for k in SalaryAmount SalaryCurrency TrialFrom TrialTo; do
  [ "$(audit_has insert "\"$k\"")" = "1" ] && ok "snapshot carries $k" || bad "snapshot is missing $k"
done
if [ "$(audit_has insert '"Salary":')" = "0" ] && [ "$(audit_has insert '"Trial":')" = "0" ]; then
  ok "the composite itself is absent — only its parts are audited"
else
  bad "the composite itself appears in the audit timeline — only its parts should"
fi

title "4.2 An update that touches ONE part deltas only that part"
expect_status "raise the salary" 200 PUT "/qa/contracts/$CT_ID" \
  '{"code":"CT-9911","salaryAmount":920000,"salaryCurrency":"BRL","trialFrom":"2026-01-06T00:00:00Z","trialTo":null}'
[ "$(audit_has update '"SalaryAmount"')" = "1" ] && ok "the changed part is in the delta" || bad "SalaryAmount missing from the delta"
if [ "$(audit_has update '"SalaryCurrency"')" = "0" ]; then
  ok "the unchanged part is absent — the diff is per part, not per value object"
else
  bad "an UNCHANGED part appears in the delta — the diff must be per part"
fi
[ "$(audit_has update 'MoneyAmountField')" = "1" ] \
  && ok "fieldLabelKey resolves to the tag inside the value object, not to the alias" \
  || bad "the delta lost the value object's label"

##############################################################################
sec "5. Read side — a part is an ordinary field, on BOTH backings"
##############################################################################
title "5.0 Let the projection catch up with the raise from 4.2"
# The relational twin is read-your-writes; the Mongo one is eventually
# consistent, so the part filter below (salaryAmount >= 900000, which only the
# RAISED value satisfies) has to wait for the update to propagate. Without this
# the assertion races the relay, and the slower ones (SQL Server CDC capture,
# Oracle LogMiner) lose that race.
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); caught=no
while [ "$(date +%s)" -lt "$deadline" ]; do
  mcoll=$(qa_view_coll qa_contracts_view)
  n=$(docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval \
    "db.getCollection('$mcoll').countDocuments({code:'CT-9911',salary_amount:920000})" 2>/dev/null | tr -d '[:space:]')
  [ "$n" = "1" ] && { caught=yes; break; }
  sleep 1
done
[ "$caught" = yes ] && ok "the raised part reached the projection" \
  || bad "the raised part never reached the projection within ${QA_CDC_DEADLINE}s"

for surface in contracts-rel contracts; do
  title "5.x /qa/$surface — filter, sort and project by a PART"
  expect_status "filter by a part of the mandatory composite" 200 GET "/qa/$surface/?salaryAmount.gte=900000"
  N=$(jsonf "$LAST_BODY" 'len(d["data"])')
  [ "${N:-0}" -ge 1 ] && ok "$surface: ?salaryAmount.gte= selected rows ($N)" || bad "$surface: part filter returned nothing"

  expect_status "sort by a part of the optional composite" 200 GET "/qa/$surface/?orderBy=trialFrom"
  expect_status "project a single part" 200 GET "/qa/$surface/?fields=salaryAmount"
  HAS_CUR=$(jsonf "$LAST_BODY" '"yes" if any("salaryCurrency" in r for r in d["data"]) else "no"')
  [ "$HAS_CUR" = "no" ] && ok "$surface: ?fields= pruned the sibling part" || bad "$surface: ?fields= did not prune"

  expect_status "onlyTotal over a part filter" 200 GET "/qa/$surface/?salaryCurrency=BRL&onlyTotal=true"
done

##############################################################################
hr
printf '\033[1mComposite value objects: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
