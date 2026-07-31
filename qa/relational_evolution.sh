#!/usr/bin/env bash
# RelationalSource EVOLUTION suite — the mongo↔relational drift transitions end to
# end, driven through a single flippable view (gadgets_evolve) via
# patch-rebuild-reboot, the same harness schema_evolution.sh uses. Each flip of the
# RelationalSource marker is a shape change (the rebuild hash carries a `relational`
# tag), so — like any shape change — it MUST bump the view Version; the suite bumps
# it at every transition and asserts the drift engine's decision at the next boot:
#
#   P0  Baseline (Mongo, V1)      — seed 3 via API, CDC materializes gadgets_evolve.
#   P1  Mongo → Relational (V2)   — DriftRelationalSync: registry synced, NO rebuild,
#                                   Mongo collection untouched, reads now hit the SoR
#                                   (a fresh write is visible with NO CDC wait).
#   P2  Relational → Mongo (V3)   — a rebuild fires, the Mongo collection is rebuilt
#                                   from the SoR (every row, incl. the P1 write).
#   P3  New Mongo over EXISTING data — drop the registry row + collection while the
#                                   SoR keeps its rows → DriftFreshBackfill rebuilds
#                                   and BACKFILLS the pre-existing rows (the historical
#                                   "a fresh Mongo view must not come up empty" bug).
#   P4  New Relational over EXISTING data — drop the registry + collection, boot the
#                                   relational variant → DriftFreshInit: registry only,
#                                   NO rebuild, no Mongo collection, reads from the SoR.
#
# Self-managed; qa binary (-tags '<engine> qa') + microservice.qa.yaml, with
# QA_RELATIONAL_EVOLVE=1 so the flippable view is contributed. SERIAL (patches the
# source tree + rebuilds). ALWAYS restores relational_evolve_infra.go on exit.
# Dialect-driven via qa/_backend.sh.  Run from anywhere:  bash qa/relational_evolution.sh
set -u

BASE="${BASE:-http://localhost:8080}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SRC="$REPO_ROOT/internal/infra/qafixtures/relational_evolve_infra.go"
BAK="/tmp/omnicore-qa-relational-evolve-${BACKEND:-postgres}.go.bak"
LOG="/tmp/omnicore-example-users-qa-relational-evolution-${BACKEND:-postgres}.log"
VIEW="gadgets_evolve"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
assert_eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[1;32m✔\033[0m %s: %s\n' "$1" "$3"; else FAIL=$((FAIL+1)); printf '  \033[1;31m✘\033[0m %s: got %q, want %q\n' "$1" "$3" "$2"; fi; }
assert_ge() { if [ "${3:-0}" -ge "$2" ] 2>/dev/null; then PASS=$((PASS+1)); printf '  \033[1;32m✔\033[0m %s: %s (>= %s)\n' "$1" "$3" "$2"; else FAIL=$((FAIL+1)); printf '  \033[1;31m✘\033[0m %s: got %s, want >= %s\n' "$1" "$3" "$2"; fi; }
assert_log()     { if grep -F -q "$2" "$LOG"; then PASS=$((PASS+1)); printf '  \033[1;32m✔\033[0m %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  \033[1;31m✘\033[0m %s: log missing %q\n' "$1" "$2"; tail -n 20 "$LOG" >&2; fi; }
assert_no_log()  { if grep -F -q "$2" "$LOG"; then FAIL=$((FAIL+1)); printf '  \033[1;31m✘\033[0m %s: log unexpectedly has %q\n' "$1" "$2"; else PASS=$((PASS+1)); printf '  \033[1;32m✔\033[0m %s\n' "$1"; fi; }

restore_src() { [ -f "$BAK" ] && cp "$BAK" "$SRC"; }
cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port "${HTTP_PORT:-8080}"
  restore_src
  qa_view_drop gadgets gadgets_hot gadgets_capped gadgets_embedded gadgets_evolve gadget_notes qa_lens_brands_view qa_widgets_view upstream_gadgets
}
trap cleanup EXIT INT TERM

# reg <field> — read a column from the gadgets_evolve registry row.
reg() { qa_db_query "SELECT $1 FROM omnicore_mongo_views WHERE view_name='$VIEW';" | tr -d ' '; }
# evolve_count — countDocuments in the ACTIVE slot of gadgets_evolve.
evolve_count() {
  local coll; coll=$(qa_view_coll "$VIEW")
  docker exec omnicore-qa-mongo mongosh "$QA_MONGO_DB" --quiet --eval \
    "print(db.getCollection('$coll').countDocuments({}))" 2>/dev/null | tail -1 | tr -d ' '
}
# api_count <path> — data length of a list endpoint.
api_count() { curl -sS "$BASE$1" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("data",[])))' 2>/dev/null; }
# rebuild_lines — count view.rebuild.start lines naming gadgets_evolve in THIS boot log.
rebuild_lines() { grep "view.rebuild.start" "$LOG" 2>/dev/null | grep -c "$VIEW" || true; }

seed_g() { curl -sS -o /dev/null -X POST "$BASE/qa/gadgets" -H "Content-Type: application/json" \
  --data "{\"code\":\"$1\",\"name\":\"$2\",\"category\":\"cat\",\"status\":\"active\"}"; }

# build_variant <mongo|relational> <version> <out> — patch the marker + Version from
# the pristine backup, build the qa binary, restore the source immediately.
build_variant() {
  local mode="$1" ver="$2" out="$3"
  if [ "$mode" = "relational" ]; then
    perl -0pe "s/Version\\(\\d+\\)/Version($ver)/; s|\\t_ = loader // RELATIONAL_EVOLVE_MARKER|\\tv = v.RelationalSource(loader) // RELATIONAL_EVOLVE_MARKER|;" "$BAK" > "$SRC"
    grep -q "RelationalSource(loader)" "$SRC" || { echo "ERROR: relational patch failed" >&2; restore_src; exit 1; }
  else
    perl -0pe "s/Version\\(\\d+\\)/Version($ver)/;" "$BAK" > "$SRC"
  fi
  grep -q "Version($ver)" "$SRC" || { echo "ERROR: version patch to $ver failed" >&2; restore_src; exit 1; }
  (cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$out" ./bootstrap) || { echo "ERROR: build failed" >&2; restore_src; exit 1; }
  restore_src
}

# boot <binary> — start it (QA_RELATIONAL_EVOLVE=1), wait /readyz (rebuild runs in
# the background, so /livez is up first; /readyz gates on the rebuild finishing).
boot() {
  : > "$LOG"; kill_port "${HTTP_PORT:-8080}"
  ( cd "$REPO_ROOT" && APP_PROFILE=dev QA_RELATIONAL_EVOLVE=1 OMNICORE_CONFIG_PATH="$REPO_ROOT/microservice.qa.yaml" exec "$1" >>"$LOG" 2>&1 ) &
  SERVER_PID=$!
  local d=$(( $(date +%s) + 40 ))
  while [ "$(date +%s)" -lt "$d" ]; do curl -sf -o /dev/null "$BASE/readyz" && return 0; sleep 0.5; done
  echo "ERROR: server not ready" >&2; tail -n 40 "$LOG" >&2; return 1
}
stop() { if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""; fi; kill_port "${HTTP_PORT:-8080}"; }

##############################################################################
sec "Setup — back up source, register connector, clean slate"
##############################################################################
cp "$SRC" "$BAK" || { echo "ERROR: cannot back up $SRC" >&2; exit 1; }
"$REPO_ROOT/devops/debezium/register-connector.sh" "$QA_CONNECTOR_DIALECT" >/dev/null 2>&1 && echo "connector registered" || echo "WARN: connector registration failed"
qa_db_exec "DELETE FROM gadgets;"
qa_db_exec "DELETE FROM omnicore_mongo_views WHERE view_name LIKE 'gadgets%';"
# Drop EVERY gadgets* collection whose registry row we just cleared — a registry
# delete without the matching collection drop leaves a populated-but-uncertified
# collection (DriftAlienData → boot abort). gadgets_embedded is the extra Mongo
# view over the gadgets root when microservice.qa.yaml declares the upstream sub;
# gadgets_full is composed (no registry, no collection) so it needs no reset.
qa_view_drop gadgets gadgets_hot gadgets_capped gadgets_embedded gadgets_evolve
qa_broker_reset 2>/dev/null || true
sleep 1

##############################################################################
sec "P0 — Baseline: gadgets_evolve as a Mongo view (V1), seed 3 via API"
##############################################################################
BIN_M1="/tmp/omnicore-qa-relevolve-m1-${BACKEND}"
build_variant mongo 1 "$BIN_M1"
boot "$BIN_M1" || exit 1
qa_cdc_warmup_gadget 2>/dev/null || true
seed_g "EV-01" "One"; seed_g "EV-02" "Two"; seed_g "EV-03" "Three"
title "Wait for CDC to materialize gadgets_evolve"
d=$(( $(date +%s) + QA_CDC_DEADLINE )); ok=fail
while [ "$(date +%s)" -lt "$d" ]; do [ "$(evolve_count)" = "3" ] && { ok=ok; break; }; sleep 1; done
assert_eq "P0 gadgets_evolve materialized (Mongo)" "ok" "$ok"
assert_eq "P0 registry.version" "1" "$(reg version)"
assert_eq "P0 registry.status"  "done" "$(reg status)"
assert_eq "P0 Mongo count" "3" "$(evolve_count)"
assert_eq "P0 GET /qa/gadgets-evolve" "3" "$(api_count /qa/gadgets-evolve)"
stop

##############################################################################
sec "P1 — Mongo → Relational (V2): DriftRelationalSync, no rebuild, reads from SoR"
##############################################################################
BIN_R2="/tmp/omnicore-qa-relevolve-r2-${BACKEND}"
build_variant relational 2 "$BIN_R2"
boot "$BIN_R2" || exit 1
assert_log    "P1 log: relational registry synced (no rebuild)" "relational view registry synced (no rebuild)"
assert_eq     "P1 NO rebuild fired for $VIEW" "0" "$(rebuild_lines)"
assert_eq     "P1 registry.version bumped to 2" "2" "$(reg version)"
assert_eq     "P1 Mongo collection UNTOUCHED (still 3, sync does not rebuild)" "3" "$(evolve_count)"
title "Read-your-writes: a NEW gadget is visible on the relational view with NO CDC wait"
seed_g "EV-04" "Four"
# No sleep — the relational reader hits the SoR directly.
assert_eq "P1 relational read sees the fresh write immediately" "4" "$(api_count /qa/gadgets-evolve)"
assert_eq "P1 Mongo collection STILL 3 (not fed by the SoR write)" "3" "$(evolve_count)"
stop

##############################################################################
sec "P2 — Relational → Mongo (V3): a rebuild fires, collection rebuilt from the SoR"
##############################################################################
BIN_M3="/tmp/omnicore-qa-relevolve-m3-${BACKEND}"
build_variant mongo 3 "$BIN_M3"
boot "$BIN_M3" || exit 1
assert_ge "P2 rebuild fired for $VIEW" 1 "$(rebuild_lines)"
assert_eq "P2 registry.version bumped to 3" "3" "$(reg version)"
title "The rebuild backfilled ALL 4 SoR rows (incl. the P1 relational-era write)"
d=$(( $(date +%s) + QA_CDC_DEADLINE )); ok=fail
while [ "$(date +%s)" -lt "$d" ]; do [ "$(evolve_count)" = "4" ] && { ok=ok; break; }; sleep 1; done
assert_eq "P2 Mongo collection rebuilt to 4" "4" "$(evolve_count)"
assert_eq "P2 GET /qa/gadgets-evolve (from Mongo)" "4" "$(api_count /qa/gadgets-evolve)"
stop

##############################################################################
sec "P3 — New Mongo view over EXISTING data → DriftFreshBackfill backfills"
##############################################################################
title "Drop the registry row + collection; the SoR keeps its 4 rows"
qa_db_exec "DELETE FROM omnicore_mongo_views WHERE view_name='$VIEW';"
qa_view_drop "$VIEW"
assert_eq "P3 registry row removed" "0" "$(qa_db_query "SELECT count(*) FROM omnicore_mongo_views WHERE view_name='$VIEW';" | tr -d ' ')"
assert_ge "P3 SoR still holds the rows" 4 "$(qa_db_query "SELECT count(*) FROM gadgets;" | tr -d ' ')"
# Reuse the Mongo V3 binary: gadgets_evolve now has NO registry but the SoR is
# populated → the fresh-view-over-existing-data case.
boot "$BIN_M3" || exit 1
assert_ge  "P3 rebuild fired ($VIEW is fresh over existing data)" 1 "$(rebuild_lines)"
title "The pre-existing rows were backfilled (NOT an empty fresh collection)"
d=$(( $(date +%s) + QA_CDC_DEADLINE )); ok=fail
while [ "$(date +%s)" -lt "$d" ]; do [ "$(evolve_count)" = "4" ] && { ok=ok; break; }; sleep 1; done
assert_eq "P3 fresh Mongo view backfilled to 4 (not 0)" "4" "$(evolve_count)"
stop

##############################################################################
sec "P4 — New Relational view over EXISTING data → DriftFreshInit, no Mongo"
##############################################################################
title "Drop the registry row + collection again; boot the RELATIONAL variant"
qa_db_exec "DELETE FROM omnicore_mongo_views WHERE view_name='$VIEW';"
qa_view_drop "$VIEW"
BIN_R4="/tmp/omnicore-qa-relevolve-r4-${BACKEND}"
build_variant relational 4 "$BIN_R4"
boot "$BIN_R4" || exit 1
assert_log    "P4 log: registry initialized (FreshInit, no rebuild)" "view registry initialized"
assert_eq     "P4 NO rebuild fired for $VIEW" "0" "$(rebuild_lines)"
assert_eq     "P4 Mongo collection NOT recreated (relational projects nothing)" "0" "$(evolve_count)"
assert_eq     "P4 GET /qa/gadgets-evolve (from the SoR) sees all 4" "4" "$(api_count /qa/gadgets-evolve)"
stop

##############################################################################
sec "Summary"
##############################################################################
printf '\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
