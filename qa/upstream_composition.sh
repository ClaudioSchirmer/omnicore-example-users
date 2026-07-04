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
# `gadgets_composed` one-to-one-embeds that projection under "upstreamMirror" and
# serves it over GET /qa/gadgets-composed/:id — proving the composition is
# readable through a normal ViewReader endpoint, not just via a direct Mongo
# query; (2) onUpstreamDelete=cascade removes the local doc (and 404s the composed
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
SERVER_BIN="/tmp/omnicore-example-users-qa-upstream-comp"
SERVER_LOG="/tmp/omnicore-example-users-qa-upstream-comp.log"
QA_YAML="$REPO_ROOT/microservice.qa.yaml"
UP_COLL="upstream_gadgets"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
cleanup() { if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi; kill_port 8080; docker exec omnicore-example-mongo mongosh "$QA_MONGO_DB" --quiet --eval "db.gadgets.drop(); db.gadgets_hot.drop(); db.gadgets_capped.drop(); db.gadgets_composed.drop(); db.upstream_gadgets.drop()" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

mongo_up() {  # eval a mongosh expression against the upstream collection
  docker exec omnicore-example-mongo mongosh "$QA_MONGO_DB" --quiet --eval "$1" 2>/dev/null | tail -1 | tr -d ' '
}

##############################################################################
sec "0. Build qa binary + ensure outbox connector + boot with qa.yaml"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port 8080

title "0.2 Ensure the outbox Debezium connector is registered (routes gadgets.events)"
"$REPO_ROOT/devops/debezium/register-connector.sh" "$QA_CONNECTOR_DIALECT" >/dev/null 2>&1 && ok "outbox connector registered" || bad "outbox connector registration failed"

title "0.3 Start server (APP_PROFILE=dev, config=microservice.qa.yaml → upstreamSubscriptions active)"
: > "$SERVER_LOG"
( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$QA_YAML" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
deadline=$(( $(date +%s) + 30 )); healthy=fail
while [ "$(date +%s)" -lt "$deadline" ]; do curl -sf -o /dev/null "$BASE/health" && { healthy=ok; break; }; sleep 0.5; done
[ "$healthy" = ok ] && ok "server ready" || { bad "server not ready"; tail -n 40 "$SERVER_LOG"; exit 1; }

title "0.4 Reset gadgets + upstream_gadgets + gadgets view collection"
qa_db_exec "DELETE FROM gadget_journal;" 2>/dev/null || true
qa_db_exec "DELETE FROM gadgets;"
qa_db_exec "DELETE FROM omnicore_upstream_failures;" 2>/dev/null || true
docker exec omnicore-example-mongo mongosh "$QA_MONGO_DB" --quiet --eval "db.gadgets.deleteMany({}); db.$UP_COLL.deleteMany({})" >/dev/null 2>&1 || true
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
deadline=$(( $(date +%s) + 40 )); seen=fail
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
sec "1.5 Composed read endpoint serves the mirror through a view (not mongosh)"
##############################################################################
# gadgets_composed one-to-one-embeds upstream_gadgets under "upstreamMirror".
# Reading it proves the composition end to end: the flat gadget PLUS the nested
# mirror the ripple recomposed — the read surface that makes the projection
# consumable over HTTP instead of only via a direct Mongo query.
GCB="$BASE/qa/gadgets-composed/$GID"
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

title "1.5.1 GET /qa/gadgets-composed/:id returns the composed doc with the mirror rippled in"
deadline=$(( $(date +%s) + 40 )); composed=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  curl -sS -o /tmp/qa-gc.json "$GCB"
  MC=$(get_field data.upstreamMirror.code /tmp/qa-gc.json)
  [ "$MC" = "UP-001" ] && { composed=ok; break; }
  sleep 1
done
[ "$composed" = ok ] && ok "composed endpoint serves upstreamMirror.code=UP-001 (ripple recomposed the embed)" || { bad "composed doc never carried the mirror"; cat /tmp/qa-gc.json 2>/dev/null; tail -n 25 "$SERVER_LOG"; }

title "1.5.2 The nested mirror carries [id, code, name] but NOT the filtered-out category/status"
MNAME=$(get_field data.upstreamMirror.name /tmp/qa-gc.json)
MCAT=$(get_field data.upstreamMirror.category /tmp/qa-gc.json)
MSTATUS=$(get_field data.upstreamMirror.status /tmp/qa-gc.json)
echo "mirror: name='$MNAME' category='$MCAT' status='$MSTATUS'"
[ "$MNAME" = "Upstream One" ] && ok "mirror carries the allow-listed name" || bad "mirror name missing"
{ [ -z "$MCAT" ] && [ -z "$MSTATUS" ]; } && ok "mirror omits filtered-out category/status" || bad "mirror leaked category/status"

title "1.5.3 The root gadget still carries category/status (root vs mirror distinction)"
RCAT=$(get_field data.category /tmp/qa-gc.json)
RSTATUS=$(get_field data.status /tmp/qa-gc.json)
{ [ "$RCAT" = "secret-cat" ] && [ "$RSTATUS" = "active" ]; } && ok "root gadget keeps its full field set" || bad "root gadget fields missing (cat='$RCAT' status='$RSTATUS')"
rm -f /tmp/qa-gc.json

##############################################################################
sec "2. onUpstreamDelete=cascade removes the local projection"
##############################################################################
title "2.1 DELETE the gadget → gadgets.events DELETED → upstream doc cascades away"
curl -sS -o /dev/null -X DELETE "$BASE/qa/gadgets/$GID"
deadline=$(( $(date +%s) + 40 )); gone=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  c=$(mongo_up "db.$UP_COLL.countDocuments({code:'UP-001'})")
  [ "${c:-1}" = "0" ] && { gone=ok; break; }
  sleep 1
done
[ "$gone" = ok ] && ok "upstream projection removed on upstream DELETE (cascade policy)" || bad "upstream doc survived the delete"

title "2.2 The composed read endpoint 404s after the gadget is hard-deleted"
deadline=$(( $(date +%s) + 40 )); notfound=fail
while [ "$(date +%s)" -lt "$deadline" ]; do
  ST=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/qa/gadgets-composed/$GID")
  [ "$ST" = "404" ] && { notfound=ok; break; }
  sleep 1
done
[ "$notfound" = ok ] && ok "composed endpoint returns 404 once the root gadget is gone" || bad "composed endpoint still served the deleted gadget (status $ST)"

##############################################################################
sec "3. Failure registry + admin drain route"
##############################################################################
title "3.1 omnicore_upstream_failures has no pending rows on the happy path"
PENDING=$(qa_db_query "SELECT count(*) FROM omnicore_upstream_failures WHERE resolved_at IS NULL;" 2>/dev/null | tr -d ' ')
[ "${PENDING:-0}" = "0" ] && ok "no pending upstream failures" || bad "unexpected pending failures: $PENDING"

title "3.2 POST /admin/retries/upstream drains (responds 200)"
ST=$(curl -sS -o /tmp/qa-up-retry.json -w "%{http_code}" -X POST "$BASE/admin/retries/upstream")
echo "response: $(cat /tmp/qa-up-retry.json 2>/dev/null)"
[ "$ST" = "200" ] && ok "admin upstream-retry route responds 200" || bad "admin retry status $ST"
rm -f /tmp/qa-up-retry.json

##############################################################################
sec "Cleanup + Summary"
##############################################################################
qa_db_exec "DELETE FROM gadgets;" 2>/dev/null || true
# DROP the qa collections so the canonical (non-qa) binary's boot registry
# guard does not later abort on foreign collections it cannot map to a view.
docker exec omnicore-example-mongo mongosh "$QA_MONGO_DB" --quiet --eval "db.gadgets.drop(); db.gadgets_composed.drop(); db.$UP_COLL.drop()" >/dev/null 2>&1 || true
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
