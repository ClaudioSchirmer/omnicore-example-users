#!/usr/bin/env bash
# Old-state + archive-as-an-update suite — the END-TO-END counterpart of the
# unit tests behind four framework guarantees. Everything here is asserted from
# OUTSIDE the process: a SQL column, a projected Mongo document, or an audit row.
#
#   1. domain.Old is captured when the entity is BORN (the load), not when the
#      Get* verb runs — on all four verbs that have an old state.
#   2. An IfUpdate rule can finish the write as an archive (CompleteAsArchive).
#   3. A domain rule OR a command's ApplyTo may change any field during archive
#      and unarchive, and that change REACHES THE RELATIONAL ROW. This is the
#      regression that motivated collapsing the two verbs onto the update path:
#      the mutation used to reach the CDC payload (and therefore Mongo) while
#      the row kept the old value, so the read model served a state the system
#      of record never held.
#   4. The child cascade still archives and restores the aggregate's children
#      around all of that, without touching their business fields.
#
# The fixture is the qa-only Tenant aggregate (`//go:build qa`, qa_tenants +
# qa_tenant_seats). Two things make its assertions discriminating rather than
# vacuous:
#
#   - every bodyless command MUTATES the entity inside ApplyTo, in the window
#     between the load and the Get* call, so a late Old snapshot would be
#     visibly different from a birth-time one; and
#   - BuildRules copies whatever domain.Old exposes into two ordinary persisted
#     columns (old_status_seen / old_plan_seen), so "what Old saw" is a SELECT.
#
# Self-managed; qa binary (-tags '<engine> qa') + microservice.qa.yaml + CDC.
# Dialect-driven via qa/_backend.sh.  Run from anywhere:
#   bash qa/old_state_archive.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-old-state-archive-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-old-state-archive-${BACKEND:-postgres}.log"

# The plan values each bodyless verb stamps from its ApplyTo. They MUST match
# the constants in internal/application/qafixtures/tenant_app.go — they are the
# control variable for both the "Old did not see it" and the "the row did see
# it" halves of the suite.
PLAN_BY_ARCHIVE="plan-by-archive-applyto"
PLAN_BY_UNARCHIVE="plan-by-unarchive-applyto"
PLAN_BY_DELETE="plan-by-delete-applyto"

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
  qa_db_exec "DELETE FROM qa_tenant_seats;" 2>/dev/null || true
  qa_db_exec "DELETE FROM qa_tenants;" 2>/dev/null || true
  # A qa-binary boot creates the qa collections via view registration; drop them
  # so a later non-qa prd suite does not abort on foreign collections.
  qa_view_drop qa_tenants_view gadgets gadget_notes gadgets_hot gadgets_capped upstream_gadgets
}
trap cleanup EXIT INT TERM

# ── assertion helpers ────────────────────────────────────────────────────────

# dbv <sql> — single scalar, whitespace-stripped. Every value this suite reads
# is a token without internal spaces (status, plan, 0/1, a count), so the strip
# is safe and makes the four dialects' output shapes converge.
dbv() { qa_db_query "$1" | head -1 | tr -d '[:space:]\r'; }

# root <column> <code> — one column of one tenant, keyed by its business code.
# Keying on code instead of id keeps every statement dialect-free: id is UUID on
# Postgres, BINARY(16) on MySQL/SQL Server and RAW(16) on Oracle.
root() { dbv "SELECT $1 FROM qa_tenants WHERE code='$2';"; }

# archived_flag <table> <where> — 1 when deleted_at is set, 0 when it is NULL.
# CASE, not a bare boolean expression: SQL Server and Oracle cannot select one.
archived_flag() { dbv "SELECT CASE WHEN deleted_at IS NULL THEN 0 ELSE 1 END FROM $1 WHERE $2;"; }

# eq <actual> <expected> <message>
eq() {
  if [ "$1" = "$2" ]; then ok "$3 ($2)"; else bad "$3 — got '$1', want '$2'"; fi
}

# tenant_id <code> — the aggregate id as canonical text, for the audit endpoint
# (audit_events.aggregate_id is a plain VARCHAR on every dialect).
tenant_id() { dbv "SELECT $(qa_uuid_select id) FROM qa_tenants WHERE code='$1';"; }

# create_tenant <code> <status> <plan> <seats-json> → echoes the new id.
# A failed seed is reported HERE rather than surfacing later as a puzzling
# assertion failure about a value that was never written.
create_tenant() {
  local body resp id
  body=$(printf '{"code":"%s","status":"%s","plan":"%s","seats":%s}' "$1" "$2" "$3" "$4")
  resp=$(curl -sS -X POST "$BASE/qa/tenants" -H 'Content-Type: application/json' --data "$body")
  id=$(printf '%s' "$resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("data",{}).get("id",""))
except Exception: print("")' 2>/dev/null)
  [ -n "$id" ] || bad "seeding tenant $1 failed: $resp"
  printf '%s' "$id"
}

# doc_field <code> <mongo-field> — one field of the projected document, read
# straight from the view's ACTIVE collection (blue-green aware via qa_view_coll).
# The document stores PHYSICAL column names, which is what lets the suite compare
# it to the relational row without a translation table.
doc_field() {
  local coll; coll=$(qa_view_coll qa_tenants_view)
  docker exec "$QA_MONGO_CONTAINER" mongosh "$QA_MONGO_DB" --quiet --eval \
    "var d=db.getCollection('$coll').findOne({code:'$1'}); print(d===null?'<no-doc>':String(d['$2']))" 2>/dev/null | tr -d '[:space:]\r'
}

# wait_doc <code> <field> <expected> — poll the projection until it converges.
wait_doc() {
  local deadline; deadline=$(( $(date +%s) + QA_CDC_DEADLINE ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(doc_field "$1" "$2")" = "$3" ] && return 0
    sleep 1
  done
  return 1
}

# seat_shape <id> <query-suffix> — "<count> <how-many-carry-deletedAt>" as read
# from the projection through HTTP.
seat_shape() {
  curl -sS "$BASE/qa/tenants/$1$2" | python3 -c 'import sys,json
try:
  s=json.load(sys.stdin).get("data",{}).get("tenantSeats",[])
  print("%d %d" % (len(s), sum(1 for x in s if x.get("deletedAt"))))
except Exception: print("0 0")' 2>/dev/null
}

# wait_seats <id> <query-suffix> <expected> — poll until the projected child
# array takes the expected shape. Every read of the child array needs this: the
# projection is eventually consistent and the CDC lag differs by an order of
# magnitude across the lanes (Oracle LogMiner mines on a cadence).
wait_seats() {
  local deadline; deadline=$(( $(date +%s) + QA_CDC_DEADLINE ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(seat_shape "$1" "$2")" = "$3" ] && return 0
    sleep 1
  done
  return 1
}

# audit_json <aggregate-id> — the framework's own audit read endpoint for this
# tenant. Used instead of parsing the payload column: the JSON/CLOB shapes
# diverge across the four dialects, the HTTP answer does not. It takes an ID and
# not a code on purpose — the delete case has no row left to resolve a code
# against, so every caller keeps the id the insert handed back.
audit_json() { curl -sS "$BASE/audit/Tenant/$1"; }

# audit_pick <aggregate-id> <verb> <python-expr over `e`> — evaluate an expression
# against the FIRST audit entry matching <verb>. Prints "<none>" when there is no match.
audit_pick() {
  audit_json "$1" | VERB="$2" EXPR="$3" python3 -c 'import sys,json,os
try:
  d=json.load(sys.stdin).get("data",[])
  for e in d:
    if e.get("verb")==os.environ["VERB"]:
      print(eval(os.environ["EXPR"])); break
  else: print("<none>")
except Exception: print("<none>")' 2>/dev/null
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
deadline=$(( $(date +%s) + 40 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready (PID=$SERVER_PID)" || { bad "server not ready"; tail -n 30 "$SERVER_LOG"; exit 1; }

# Prove the CDC pipeline is hot before any per-step deadline starts counting.
qa_cdc_warmup_gadget

title "0.3 Reset qa_tenants + qa_tenant_seats + the projection"
qa_db_exec "DELETE FROM qa_tenant_seats;"
qa_db_exec "DELETE FROM qa_tenants;"
qa_view_clear qa_tenants_view
ok "clean tenant baseline"

##############################################################################
sec "1. domain.Old is captured at BIRTH, on every verb that has an old state"
##############################################################################
# Each step below mutates the entity between the load and the verb, then asks
# what Old saw. Birth-time capture ⇒ the probe holds the LOADED value. A
# snapshot taken at the Get* call would hold the mutated one, and every
# assertion in this section would flip.

title "1.1 Seed OS-1 (trial / starter) with two seats"
ID=$(create_tenant "OS-1" "trial" "starter" '[{"label":"seat-a","seat":1},{"label":"seat-b","seat":2}]')
[ -n "$ID" ] && ok "insert returned id $ID" || { bad "insert failed"; }
# "none" and not "": Oracle stores the empty string as NULL, which a non-pointer
# Go string field cannot scan back. The fixture writes an explicit sentinel so
# one shape holds on all four dialects (see qadomain.TenantNoOldState).
eq "$(root old_status_seen OS-1)" "none" "insert records that there was no old state"

title "1.2 UPDATE — the probe holds the LOADED status/plan, not the body's"
curl -sS -o /dev/null -X PUT "$BASE/qa/tenants/$ID" -H 'Content-Type: application/json' \
  --data '{"code":"OS-1","status":"active","plan":"growth"}'
eq "$(root status OS-1)"          "active"  "the update persisted the new status"
eq "$(root plan_code OS-1)"       "growth"  "the update persisted the new plan"
eq "$(root old_status_seen OS-1)" "trial"   "IfUpdate saw the PRE-update status"
eq "$(root old_plan_seen OS-1)"   "starter" "IfUpdate saw the PRE-update plan"

title "1.3 ARCHIVE — ApplyTo changes the plan first; Old must not see that"
curl -sS -o /dev/null -X PATCH "$BASE/qa/tenants/$ID/archive"
eq "$(root old_status_seen OS-1)" "active" "IfArchive saw the status as LOADED"
eq "$(root old_plan_seen OS-1)"   "growth" "IfArchive saw the plan as LOADED, not the value ApplyTo had just written"

title "1.4 UNARCHIVE — same window, same guarantee"
curl -sS -o /dev/null -X PATCH "$BASE/qa/tenants/$ID/unarchive"
eq "$(root old_status_seen OS-1)" "suspended"       "IfUnarchive saw the archived status"
eq "$(root old_plan_seen OS-1)"   "$PLAN_BY_ARCHIVE" "IfUnarchive saw the plan the ARCHIVE left behind, not the one its own ApplyTo just wrote"

title "1.5 DELETE — the kind=snapshot audit event describes the row as LOADED"
# The row is gone, so the probe here is the audit trail. BuildDeleteEvent builds
# its snapshot FROM the old state: it must describe the tenant as loaded, never
# as DeleteTenantCommand.ApplyTo left it.
DEL_ID=$(create_tenant "OS-DEL" "active" "enterprise" '[{"label":"d1","seat":1}]')
curl -sS -o /dev/null -X DELETE "$BASE/qa/tenants/$DEL_ID"
SNAP_PLAN=$(audit_json "$DEL_ID" | python3 -c 'import sys,json
try:
  for e in json.load(sys.stdin).get("data",[]):
    if e.get("verb")=="delete": print(e.get("snapshot",{}).get("Plan","<none>")); break
  else: print("<none>")
except Exception: print("<none>")' 2>/dev/null)
eq "$SNAP_PLAN" "enterprise" "the delete snapshot holds the LOADED plan"
[ "$SNAP_PLAN" = "$PLAN_BY_DELETE" ] && bad "the delete snapshot leaked the ApplyTo mutation — Old was captured late" || ok "the snapshot did NOT leak the ApplyTo mutation"

##############################################################################
sec "2. CompleteAsArchive — a domain rule finishes an UPDATE as an archive"
##############################################################################
title "2.1 PUT status=closing on an ordinary update route"
CA_ID=$(create_tenant "OS-CA" "active" "growth" '[{"label":"c1","seat":1},{"label":"c2","seat":2}]')
ST=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "$BASE/qa/tenants/$CA_ID" -H 'Content-Type: application/json' \
  --data '{"code":"OS-CA","status":"closing","plan":"growth"}')
eq "$ST" "200" "the update answered 200"

title "2.2 The row is ARCHIVED, not merely updated"
eq "$(archived_flag qa_tenants "code='OS-CA'")" "1" "deleted_at was stamped by an UPDATE request"
eq "$(root status OS-CA)" "suspended" "the status the IfUpdate closure left behind is what persisted"

title "2.3 IfArchive did NOT fire on this path"
# CompleteAsArchive does not re-run the rules in ModeArchive. The discriminator
# is the plan: the archive VERB's ApplyTo stamps PLAN_BY_ARCHIVE, and this write
# never went through it, so the plan must still be the PUT body's.
eq "$(root plan_code OS-CA)" "growth" "the plan is the update body's, so the archive command never ran"
[ "$(root plan_code OS-CA)" = "$PLAN_BY_ARCHIVE" ] && bad "the archive command's ApplyTo ran — CompleteAsArchive re-entered the archive verb" || ok "the archive verb's own ApplyTo did not run"

title "2.4 The audit event proves the door it came through"
eq "$(audit_pick "$CA_ID" archive 'e.get("verb","")')"       "archive"      "the framework recorded a real ARCHIVE"
eq "$(audit_pick "$CA_ID" archive 'e.get("kind","")')"       "transition"   "kind stayed transition"
eq "$(audit_pick "$CA_ID" archive 'e.get("actionName","")')" "GetUpdatable" "actionName names the UPDATE entry point (a plain archive says GetArchivable)"
eq "$(audit_pick "$CA_ID" archive 'len(e.get("changes",[]))>0')" "True"     "the transition carries the ADDITIVE changes block (the verb persisted a domain change)"

title "2.5 Old was captured at birth here too"
eq "$(root old_status_seen OS-CA)" "active" "IfUpdate saw the pre-update status on the CompleteAsArchive path"

##############################################################################
sec "3. Archive and unarchive carry an extra change INTO THE RELATIONAL ROW"
##############################################################################
# The regression this section exists to keep dead: a domain rule (or a command's
# ApplyTo) mutating the entity during archive/unarchive used to reach the CDC
# payload and Mongo while the row kept its old value.

title "3.1 Seed OS-BUG and archive it"
BUG_ID=$(create_tenant "OS-BUG" "trial" "starter" '[{"label":"b1","seat":1},{"label":"b2","seat":2}]')
REV_BEFORE=$(root revision OS-BUG)
UPD_BEFORE=$(dbv "SELECT updated_at FROM qa_tenants WHERE code='OS-BUG';")
# Cross a whole-second boundary before archiving. The canonical MySQL tables
# declare updated_at as a plain DATETIME (second precision) and this fixture
# mirrors that shape deliberately, so an insert and an archive inside the same
# second would render identically and 3.4 could not tell "stamped again" from
# "never touched". The other three dialects carry sub-second precision and do
# not need it; one second is cheaper than a fixture that diverges from what the
# real service actually stores.
sleep 1.1
curl -sS -o /dev/null -X PATCH "$BASE/qa/tenants/$BUG_ID/archive"

title "3.2 The DOMAIN RULE's mutation reached the row"
eq "$(root status OS-BUG)" "suspended" "IfArchive's status change is IN THE SYSTEM OF RECORD"

title "3.3 The COMMAND's mutation reached the row"
eq "$(root plan_code OS-BUG)" "$PLAN_BY_ARCHIVE" "the archive command's ApplyTo change is in the row too"

title "3.4 Archive executed the UPDATE path (revision + updated_at moved)"
eq "$(archived_flag qa_tenants "code='OS-BUG'")" "1" "the row is archived"
REV_AFTER=$(root revision OS-BUG)
[ "$REV_AFTER" -gt "$REV_BEFORE" ] 2>/dev/null && ok "revision bumped ($REV_BEFORE → $REV_AFTER) — archive is a real mutation" \
  || bad "revision did not bump ($REV_BEFORE → $REV_AFTER)"
UPD_AFTER=$(dbv "SELECT updated_at FROM qa_tenants WHERE code='OS-BUG';")
[ "$UPD_AFTER" != "$UPD_BEFORE" ] && ok "updated_at moved — archive stamps it like any other write" \
  || bad "updated_at did not move ($UPD_BEFORE)"

title "3.5 The PROJECTION tells the same story as the row — no lie in Mongo"
if wait_doc OS-BUG status suspended; then
  ok "the projected status converged to the row's value"
else
  bad "the projection never converged on status (want suspended, got '$(doc_field OS-BUG status)')"
fi
eq "$(doc_field OS-BUG plan_code)"       "$(root plan_code OS-BUG)"       "document plan_code == row plan_code"
eq "$(doc_field OS-BUG status)"          "$(root status OS-BUG)"          "document status == row status"
eq "$(doc_field OS-BUG old_status_seen)" "$(root old_status_seen OS-BUG)" "document old_status_seen == row old_status_seen"
eq "$(doc_field OS-BUG old_plan_seen)"   "$(root old_plan_seen OS-BUG)"   "document old_plan_seen == row old_plan_seen"

title "3.6 Unarchive carries its own changes back into the row"
curl -sS -o /dev/null -X PATCH "$BASE/qa/tenants/$BUG_ID/unarchive"
eq "$(root status OS-BUG)"                       "active"             "IfUnarchive's status change reached the row"
eq "$(root plan_code OS-BUG)"                    "$PLAN_BY_UNARCHIVE" "the unarchive command's ApplyTo change reached the row"
eq "$(archived_flag qa_tenants "code='OS-BUG'")" "0"                  "deleted_at was cleared"

title "3.7 The projection follows the unarchive too"
if wait_doc OS-BUG status active; then
  ok "the projected status converged back to active"
else
  bad "the projection never converged on the unarchive (got '$(doc_field OS-BUG status)')"
fi
eq "$(doc_field OS-BUG plan_code)" "$(root plan_code OS-BUG)" "document plan_code == row plan_code after unarchive"

##############################################################################
sec "4. The child cascade around archive and unarchive"
##############################################################################
SEATS_OF="tenant_id = (SELECT id FROM qa_tenants WHERE code='OS-CASCADE')"

title "4.1 Seed OS-CASCADE with three seats"
CAS_ID=$(create_tenant "OS-CASCADE" "active" "starter" '[{"label":"x1","seat":1},{"label":"x2","seat":2},{"label":"x3","seat":3}]')
eq "$(dbv "SELECT COUNT(*) FROM qa_tenant_seats WHERE $SEATS_OF;")" "3" "three seats persisted"

title "4.2 Archive cascades to EVERY child"
curl -sS -o /dev/null -X PATCH "$BASE/qa/tenants/$CAS_ID/archive"
eq "$(dbv "SELECT COUNT(*) FROM qa_tenant_seats WHERE $SEATS_OF AND deleted_at IS NOT NULL;")" "3" "all three seats archived"
eq "$(dbv "SELECT COUNT(*) FROM qa_tenant_seats WHERE $SEATS_OF;")" "3" "no seat was deleted — the cascade archives, it does not remove"

title "4.3 The cascade moved deleted_at and NOTHING else"
# An archive writes the full field set now; the children must come through it
# with their business fields intact.
eq "$(dbv "SELECT COUNT(*) FROM qa_tenant_seats WHERE $SEATS_OF AND label IN ('x1','x2','x3');")" "3" "every label survived the cascade"
eq "$(dbv "SELECT SUM(seat) FROM qa_tenant_seats WHERE $SEATS_OF;")" "6" "every seat number survived the cascade (1+2+3)"

title "4.4 The audit reports a real per-child op"
eq "$(audit_pick "$CAS_ID" archive 'len(e.get("children",{}).get("TenantSeat",[]))')" "3" "the archive event lists all three children"
eq "$(audit_pick "$CAS_ID" archive 'sorted(set(c["op"] for c in e.get("children",{}).get("TenantSeat",[])))')" "['archived']" "each child is reported as archived (not a placeholder op)"

title "4.5 The projected document carries the archived children"
# The root is archived, so a default read hides it entirely; ?includeArchived is
# what surfaces the aggregate, children included.
ST=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/qa/tenants/$CAS_ID")
eq "$ST" "404" "an archived tenant is hidden from a default by-id read"
if wait_doc OS-CASCADE status suspended; then ok "the archived aggregate converged in the projection"; else bad "projection did not converge"; fi
wait_seats "$CAS_ID" "?includeArchived=true" "3 3"
eq "$(seat_shape "$CAS_ID" "?includeArchived=true")" "3 3" "?includeArchived surfaces all three children, each carrying deletedAt"

title "4.6 Unarchive restores every child, fields still intact"
curl -sS -o /dev/null -X PATCH "$BASE/qa/tenants/$CAS_ID/unarchive"
eq "$(dbv "SELECT COUNT(*) FROM qa_tenant_seats WHERE $SEATS_OF AND deleted_at IS NULL;")" "3" "all three seats restored"
eq "$(dbv "SELECT SUM(seat) FROM qa_tenant_seats WHERE $SEATS_OF;")" "6" "seat numbers still intact after the round trip"
eq "$(dbv "SELECT COUNT(*) FROM qa_tenant_seats WHERE $SEATS_OF AND label IN ('x1','x2','x3');")" "3" "labels still intact after the round trip"
eq "$(audit_pick "$CAS_ID" unarchive 'sorted(set(c["op"] for c in e.get("children",{}).get("TenantSeat",[])))')" "['unarchived']" "the unarchive event reports each child as unarchived"

title "4.7 The CompleteAsArchive path cascades identically"
# The update-that-became-an-archive from section 2 must have archived its
# children too — the migration hands the write to the SAME archive machinery.
eq "$(dbv "SELECT COUNT(*) FROM qa_tenant_seats WHERE tenant_id = (SELECT id FROM qa_tenants WHERE code='OS-CA') AND deleted_at IS NOT NULL;")" "2" \
  "both seats of the CompleteAsArchive tenant were cascaded"

title "4.8 A default read shows the restored aggregate with active children"
wait_seats "$CAS_ID" "" "3 0"
eq "$(seat_shape "$CAS_ID" "")" "3 0" "the restored aggregate reads back with three children and no deletedAt"

##############################################################################
sec "5. Cleanup"
##############################################################################
qa_db_exec "DELETE FROM qa_tenant_seats;"
qa_db_exec "DELETE FROM qa_tenants;"
ok "tenant tables cleared"

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
