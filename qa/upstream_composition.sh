#!/usr/bin/env bash
# Service-to-service upstream-composition suite (via the qa-only Gadget).
#
# The framework lets service B materialize a LOCAL, filtered Mongo projection of
# service A's events (event-driven, so B never reads A on the request path). The
# canonical example wires no upstream subscription, so this was 0% covered. Here
# the SAME service plays both roles: it produces gadgets.events (outbox → the
# standard Debezium connector) and subscribes to that topic as an "upstream",
# materializing a filtered `upstream_gadgets` Mongo collection.
#
# Asserts: (1) an upstream event materializes the local projection carrying ONLY
# the allow-listed fields (filter: [id, code, name]); (1.5) the COMPOSED read view
# `gadgets_embedded` one-to-one-embeds that projection under "upstreamMirror" and
# serves it over GET /qa/gadgets-embedded/:id — proving the composition is
# readable through a normal ViewReader endpoint, not just via a direct Mongo
# query; (2) onUpstreamDelete=cascade removes the local doc (and 404s the embedded
# endpoint) when the upstream entity is deleted; (3) the failure registry stays
# empty on the happy path and the /admin/retries/upstream drain route responds.
# Uses the qa binary + microservice.qa.yaml (upstreamSubscriptions).
#
# Prereqs: docker compose up + the OUTBOX Debezium connector registered (routes
# gadgets.events). Self-managed server lifecycle. Dialect-driven via _backend.sh.
#
# Run from anywhere:  bash qa/upstream_composition.sh
set -u

BASE="${BASE:-http://localhost:8080}"
CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-upstream-comp-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-upstream-comp-${BACKEND:-postgres}.log"
QA_YAML_SRC="$REPO_ROOT/microservice.qa.yaml"
# This suite runs on a DERIVED yaml adding two policy-twin subscriptions over
# the same gadgets.events topic (anonymize + keep) for §4 — kept OUT of the
# shared microservice.qa.yaml so the other qa suites never materialize the
# twin mirrors (a later prd-profile boot would abort on the foreign
# collections its registry cannot certify).
QA_YAML="/tmp/qa-upstream-policies-${BACKEND:-postgres}.yaml"
python3 - "$QA_YAML_SRC" "$QA_YAML" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
twins = """  - topic: gadgets.events
    collection: upstream_gadgets_anon
    consumerGroup: omnicore-example-users-upstream-gadgets-anon
    workers: 1
    filter: [id, code, name]
    startFrom: earliest
    onUpstreamDelete: anonymize
    anonymizeFields: [name]
  - topic: gadgets.events
    collection: upstream_gadgets_keep
    consumerGroup: omnicore-example-users-upstream-gadgets-keep
    workers: 1
    filter: [id, code, name]
    startFrom: earliest
    onUpstreamDelete: keep
"""
out, done = [], False
for line in open(src):
    out.append(line)
    if not done and line.strip() == "onUpstreamDelete: cascade":
        out.append(twins)
        done = True
open(dst, "w").writelines(out)
PYEOF
UP_COLL="upstream_gadgets"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
cleanup() { if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi; kill_port "${HTTP_PORT:-8080}"; qa_view_drop gadgets gadget_notes gadgets_hot gadgets_capped gadgets_embedded upstream_gadgets upstream_gadgets_anon upstream_gadgets_keep; }
trap cleanup EXIT INT TERM

mongo_up() {  # eval a mongosh expression against the upstream collection
  docker exec omnicore-qa-mongo mongosh "$QA_MONGO_DB" --quiet --eval "$1" 2>/dev/null | tail -1 | tr -d ' '
}

##############################################################################
sec "0. Build qa binary + ensure outbox connector + boot with qa.yaml"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8080}"

title "0.2 Ensure the outbox Debezium connector is registered (routes gadgets.events)"
"$REPO_ROOT/devops/debezium/register-connector.sh" "$QA_CONNECTOR_DIALECT" >/dev/null 2>&1 && ok "outbox connector registered" || bad "outbox connector registration failed"

title "0.3 Start server (APP_PROFILE=dev, config=derived policy yaml → upstreamSubscriptions active incl. anonymize/keep twins)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$QA_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/livez" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready" || { bad "server not ready"; tail -n 40 "$SERVER_LOG"; exit 1; }

# Prove the CDC pipeline is hot (consumer groups joined, Debezium task live)
# BEFORE any per-step deadline starts counting; the clean-baseline step below
# sweeps the sentinel. Non-fatal — see qa/_backend.sh.
qa_cdc_warmup_gadget

title "0.4 Reset gadgets + upstream_gadgets + gadgets view collection"
qa_db_exec "DELETE FROM gadget_journal;" 2>/dev/null || true
qa_db_exec "DELETE FROM gadgets;"
qa_db_exec "DELETE FROM omnicore_upstream_failures;" 2>/dev/null || true
qa_view_clear gadgets "$UP_COLL"
sleep 1
ok "clean baseline"

##############################################################################
sec "1. Upstream event materializes a FILTERED local projection"
##############################################################################
title "1.1 POST a gadget (produces gadgets.events)"
RESP=$(curl -sS -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" \
  --data '{"code":"UP-001","name":"Upstream One","category":"secret-cat","status":"active"}')
GID=$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null)
[ -n "$GID" ] && ok "gadget created ($GID)" || { bad "create failed: $RESP"; }

title "1.2 upstream_gadgets materializes the doc (via gadgets.events → UpstreamSubscriber)"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); seen=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  c=$(mongo_up "db.$UP_COLL.countDocuments({code:'UP-001'})")
  [ "${c:-0}" -ge 1 ] 2>/dev/null && { seen=ok; break; }
  sleep 1
done
[ "$seen" = ok ] && ok "upstream_gadgets carries the projected gadget" || { bad "upstream projection never materialized"; tail -n 25 "$SERVER_LOG"; }

title "1.3 The projection keeps ONLY the allow-listed fields (filter: [id, code, name])"
HASCODE=$(mongo_up "var d=db.$UP_COLL.findOne({code:'UP-001'}); print(d && d.code ? 'y':'n')")
HASNAME=$(mongo_up "var d=db.$UP_COLL.findOne({code:'UP-001'}); print(d && d.name ? 'y':'n')")
HASCAT=$(mongo_up "var d=db.$UP_COLL.findOne({code:'UP-001'}); print(d && d.category ? 'y':'n')")
HASSTATUS=$(mongo_up "var d=db.$UP_COLL.findOne({code:'UP-001'}); print(d && d.status ? 'y':'n')")
echo "code=$HASCODE name=$HASNAME category=$HASCAT status=$HASSTATUS"
[ "$HASCODE" = y ] && [ "$HASNAME" = y ] && ok "allow-listed code + name present" || bad "allow-listed fields missing"
[ "$HASCAT" = n ] && [ "$HASSTATUS" = n ] && ok "non-allow-listed category + status filtered OUT (GDPR-style projection)" || bad "filter did not drop category/status"

##############################################################################
sec "1.5 Embedded read endpoint serves the mirror through a view (not mongosh)"
##############################################################################
# gadgets_embedded one-to-one-embeds upstream_gadgets under "upstreamMirror".
# Reading it proves the composition end to end: the flat gadget PLUS the nested
# mirror the ripple recomposed — the read surface that makes the projection
# consumable over HTTP instead of only via a direct Mongo query.
GCB="$BASE/qa/gadgets-embedded/$GID"
get_field() {  # $1 = dotted path into the JSON body, $2 = json file
  python3 -c '
import sys, json
path, fn = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(fn))
except Exception:
    print(""); sys.exit()
cur = d
for k in path.split("."):
    cur = cur.get(k) if isinstance(cur, dict) else None
print(cur if cur is not None else "")' "$1" "$2" 2>/dev/null
}

title "1.5.1 GET /qa/gadgets-embedded/:id returns the embedded doc with the mirror rippled in"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); embedded=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  curl -sS -o /tmp/qa-gc.json.${BACKEND:-default} "$GCB"
  MC=$(get_field data.upstreamMirror.code /tmp/qa-gc.json.${BACKEND:-default})
  [ "$MC" = "UP-001" ] && { embedded=ok; break; }
  sleep 1
done
[ "$embedded" = ok ] && ok "embedded endpoint serves upstreamMirror.code=UP-001 (ripple recomposed the embed)" || { bad "embedded doc never carried the mirror"; cat /tmp/qa-gc.json.${BACKEND:-default} 2>/dev/null; tail -n 25 "$SERVER_LOG"; }

title "1.5.2 The nested mirror carries [id, code, name] but NOT the filtered-out category/status"
MNAME=$(get_field data.upstreamMirror.name /tmp/qa-gc.json.${BACKEND:-default})
MCAT=$(get_field data.upstreamMirror.category /tmp/qa-gc.json.${BACKEND:-default})
MSTATUS=$(get_field data.upstreamMirror.status /tmp/qa-gc.json.${BACKEND:-default})
echo "mirror: name='$MNAME' category='$MCAT' status='$MSTATUS'"
[ "$MNAME" = "Upstream One" ] && ok "mirror carries the allow-listed name" || bad "mirror name missing"
{ [ -z "$MCAT" ] && [ -z "$MSTATUS" ]; } && ok "mirror omits filtered-out category/status" || bad "mirror leaked category/status"

title "1.5.3 The root gadget still carries category/status (root vs mirror distinction)"
RCAT=$(get_field data.category /tmp/qa-gc.json.${BACKEND:-default})
RSTATUS=$(get_field data.status /tmp/qa-gc.json.${BACKEND:-default})
{ [ "$RCAT" = "secret-cat" ] && [ "$RSTATUS" = "active" ]; } && ok "root gadget keeps its full field set" || bad "root gadget fields missing (cat='$RCAT' status='$RSTATUS')"
rm -f /tmp/qa-gc.json.${BACKEND:-default}

##############################################################################
sec "2. onUpstreamDelete=cascade removes the local projection"
##############################################################################
title "2.1 DELETE the gadget → gadgets.events DELETED → upstream doc cascades away"
curl -sS -o /dev/null -X DELETE "$BASE/qa/gadgets/$GID"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); gone=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  c=$(mongo_up "db.$UP_COLL.countDocuments({code:'UP-001'})")
  [ "${c:-1}" = "0" ] && { gone=ok; break; }
  sleep 1
done
[ "$gone" = ok ] && ok "upstream projection removed on upstream DELETE (cascade policy)" || bad "upstream doc survived the delete"

title "2.2 The embedded read endpoint 404s after the gadget is hard-deleted"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); notfound=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  ST=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/qa/gadgets-embedded/$GID")
  [ "$ST" = "404" ] && { notfound=ok; break; }
  sleep 1
done
[ "$notfound" = ok ] && ok "embedded endpoint returns 404 once the root gadget is gone" || bad "embedded endpoint still served the deleted gadget (status $ST)"

##############################################################################
sec "4. ONE upstream DELETE, all THREE onUpstreamDelete policies side by side"
##############################################################################
# Coverage audit 2026-07-21: only cascade was ever exercised. The qa yaml now
# mirrors gadgets.events into two policy twins (upstream_gadgets_anon:
# anonymize [name]; upstream_gadgets_keep: keep) — one hard delete must
# cascade-remove the first mirror, blank-and-keep the second, and leave the
# third intact.
title "4.1 POST UP-002 → all three mirrors materialize"
RESP=$(curl -sS -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" \
  --data '{"code":"UP-002","name":"Policy Probe","category":"cat","status":"active"}')
G2ID=$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null)
[ -n "$G2ID" ] && ok "gadget UP-002 created ($G2ID)" || bad "create failed: $RESP"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); three=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  a=$(mongo_up "db.$UP_COLL.countDocuments({code:'UP-002'})")
  b=$(mongo_up "db.upstream_gadgets_anon.countDocuments({code:'UP-002'})")
  c=$(mongo_up "db.upstream_gadgets_keep.countDocuments({code:'UP-002'})")
  [ "${a:-0}" = "1" ] && [ "${b:-0}" = "1" ] && [ "${c:-0}" = "1" ] && { three=ok; break; }
  sleep 1
done
[ "$three" = ok ] && ok "cascade + anonymize + keep mirrors all carry UP-002" || bad "mirrors incomplete (cascade=$a anon=$b keep=$c)"

title "4.2 DELETE UP-002 → cascade removes / anonymize blanks-and-keeps / keep leaves intact"
curl -sS -o /dev/null -X DELETE "$BASE/qa/gadgets/$G2ID"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); pol=fail; a=""; b=""; c=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  a=$(mongo_up "db.$UP_COLL.countDocuments({code:'UP-002'})")
  b=$(mongo_up "var d=db.upstream_gadgets_anon.findOne({code:'UP-002'}); print(d ? (d.name===null ? 'blanked':'kept') : 'gone')")
  c=$(mongo_up "var d=db.upstream_gadgets_keep.findOne({code:'UP-002'}); print(d && d.name==='Policy Probe' ? 'intact':'wrong')")
  [ "${a:-1}" = "0" ] && [ "$b" = "blanked" ] && [ "$c" = "intact" ] && { pol=ok; break; }
  sleep 1
done
[ "$pol" = ok ] && ok "cascade=removed, anonymize=doc kept with name blanked, keep=doc intact" \
               || bad "policy outcomes wrong (cascade_count=$a anon=$b keep=$c)"

##############################################################################
sec "5. Upstream ARCHIVED / UNARCHIVED — mirror survives with deleted_at (no deleteOnArchive)"
##############################################################################
# Coverage audit 2026-07-21: the ARCHIVED branch of the subscriber was never
# exercised. Without deleteOnArchive the contract is doc-survives-with-
# deleted_at (the upsert lands the archived state); UNARCHIVED clears it.
title "5.1 POST UP-003 + archive it → mirror doc SURVIVES carrying deleted_at"
RESP=$(curl -sS -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" \
  --data '{"code":"UP-003","name":"Archive Probe","category":"cat","status":"active"}')
G3ID=$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("data",{}).get("id",""))' 2>/dev/null)
deadline=$(( $(date +%s) + QA_CDC_DEADLINE ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ "$(mongo_up "db.$UP_COLL.countDocuments({code:'UP-003'})")" = "1" ] && break; sleep 1
done
curl -sS -o /dev/null -X PATCH "$BASE/qa/gadgets/$G3ID/archive"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); arch=fail; st=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  st=$(mongo_up "var d=db.$UP_COLL.findOne({code:'UP-003'}); print(d ? (d.deleted_at ? 'archived':'active') : 'gone')")
  [ "$st" = "archived" ] && { arch=ok; break; }
  sleep 1
done
[ "$arch" = ok ] && ok "mirror kept the doc with deleted_at set (archived state mirrored, not removed)" || bad "mirror state after ARCHIVED: $st (want archived)"

title "5.2 Unarchive → the mirror doc's deleted_at clears"
curl -sS -o /dev/null -X PATCH "$BASE/qa/gadgets/$G3ID/unarchive"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); unarch=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  st=$(mongo_up "var d=db.$UP_COLL.findOne({code:'UP-003'}); print(d ? (d.deleted_at ? 'archived':'active') : 'gone')")
  [ "$st" = "active" ] && { unarch=ok; break; }
  sleep 1
done
[ "$unarch" = ok ] && ok "UNARCHIVED cleared deleted_at on the mirror" || bad "mirror state after UNARCHIVED: $st (want active)"

##############################################################################
sec "6. deleteOnArchive: true — ARCHIVED removes the mirror; UNARCHIVED re-materializes"
##############################################################################
# The other half of the archive contract, via a derived yaml flipping the main
# subscription to deleteOnArchive: true (reboot; consumer group resumes).
title "6.1 Reboot on the deleteOnArchive variant"
if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
kill_port "${HTTP_PORT:-8080}"
DOA_YAML="/tmp/qa-upstream-doa-${BACKEND}.yaml"
python3 - "$QA_YAML" "$DOA_YAML" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
out = []
for line in open(src):
    out.append(line)
    if line.strip() == "collection: upstream_gadgets":
        out.append("    deleteOnArchive: true\n")
open(dst, "w").writelines(out)
PYEOF
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$DOA_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 90 )); rok=fail
while [ "$(date +%s)" -lt "$deadline" ]; do [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/readyz")" = 200 ] && { rok=ok; break; }; sleep 1; done
[ "$rok" = ok ] && ok "server up on deleteOnArchive variant" || bad "server never ready on the variant yaml"

title "6.2 ARCHIVE UP-003 → the mirror doc is REMOVED"
curl -sS -o /dev/null -X PATCH "$BASE/qa/gadgets/$G3ID/archive"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); doa=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ "$(mongo_up "db.$UP_COLL.countDocuments({code:'UP-003'})")" = "0" ] && { doa=ok; break; }
  sleep 1
done
[ "$doa" = ok ] && ok "deleteOnArchive removed the archived doc from the mirror" || bad "mirror doc survived ARCHIVED under deleteOnArchive"

title "6.3 UNARCHIVE UP-003 → the mirror re-materializes"
curl -sS -o /dev/null -X PATCH "$BASE/qa/gadgets/$G3ID/unarchive"
deadline=$(( $(date +%s) + QA_CDC_DEADLINE )); rem=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  st=$(mongo_up "var d=db.$UP_COLL.findOne({code:'UP-003'}); print(d ? (d.deleted_at ? 'archived':'active') : 'gone')")
  [ "$st" = "active" ] && { rem=ok; break; }
  sleep 1
done
[ "$rem" = ok ] && ok "UNARCHIVED re-materialized the mirror doc (active)" || bad "mirror after unarchive: $st (want active)"

##############################################################################
sec "3. Failure registry + admin drain route"
##############################################################################
title "3.1 omnicore_upstream_failures has no pending rows on the happy path"
PENDING=$(qa_db_query "SELECT count(*) FROM omnicore_upstream_failures WHERE resolved_at IS NULL;" 2>/dev/null | tr -d ' ')
[ "${PENDING:-0}" = "0" ] && ok "no pending upstream failures" || bad "unexpected pending failures: $PENDING"

title "3.2 POST /admin/retries/upstream drains (responds 200)"
ST=$(curl -sS -o /tmp/qa-up-retry.json.${BACKEND:-default} -w "%{http_code}" -X POST "$BASE/admin/retries/upstream")
echo "response: $(cat /tmp/qa-up-retry.json.${BACKEND:-default} 2>/dev/null)"
[ "$ST" = "200" ] && ok "admin upstream-retry route responds 200" || bad "admin retry status $ST"
rm -f /tmp/qa-up-retry.json.${BACKEND:-default}

##############################################################################
sec "Cleanup + Summary"
##############################################################################
qa_db_exec "DELETE FROM gadgets;" 2>/dev/null || true
# DROP the qa collections so the canonical (non-qa) binary's boot registry
# guard does not later abort on foreign collections it cannot map to a view.
qa_view_drop gadgets gadget_notes gadgets_embedded "$UP_COLL" upstream_gadgets_anon upstream_gadgets_keep || true
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
