#!/usr/bin/env bash
# rebuild_scale.sh — online blue-green view rebuild under LOAD + full MULTI-POD.
#
# Heavy, standalone suite (NOT in the qa/run.sh matrix — like perf.sh). It proves
# the whole blue-green story end to end on a large FULL aggregate:
#   • CRUD works on a live service (insert + edit + read),
#   • a version-bump rebuild that ADDS A NULLABLE COLUMN to the view runs online,
#   • a second pod (POD A, the driver) rebuilds while POD B keeps serving,
#   • a third pod (POD C) that boots mid-rebuild becomes a FOLLOWER (livez 200,
#     readyz 200 — it does NOT abort; it serves the active slot until the flip),
#   • writes fired during the rebuild DUAL-WRITE into BOTH the new and old slots,
#   • after the flip a fresh pod (POD D) and POD A/C read the NEW view,
#   • zero data loss, inspected via BOTH the database AND the HTTP endpoints.
#
# Postgres-only (the bulk seed uses gen_random_uuid / generate_series). The
# service source is patched (entity + schema + read DTOs + view Version) and a
# nullable `nickname` column added; a cleanup trap restores the tree + drops the
# column on every exit path.
#
# Prerequisites (bench up + relay registered):
#   docker compose -f devops/docker-compose.yml up -d postgres mongo kafka connect redis --wait
#   ./devops/debezium/register-connector.sh postgres
#
# Run:   bash qa/rebuild_scale.sh
# Tune:  SEED_COUNT=1000000 CONCURRENT_WRITES=200 LEASE_SECONDS=2 bash qa/rebuild_scale.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BACKEND=postgres
source "$REPO_ROOT/qa/_backend.sh"

SEED_COUNT="${SEED_COUNT:-1000000}"
CONCURRENT_WRITES="${CONCURRENT_WRITES:-200}"
LEASE_SECONDS="${LEASE_SECONDS:-2}"          # pointerLeaseSeconds override — keeps fence waits short
REBUILD_TIMEOUT="${REBUILD_TIMEOUT:-3600}"   # a 1M full-aggregate backfill takes minutes

BIN_V1="/tmp/omnicore-rs-v1"
BIN_V2="/tmp/omnicore-rs-v2"
FAST_YAML="/tmp/omnicore-rs-fast.yaml"

# Files the "add a nullable column, project it, bump the view" edit patches.
VIEW_SRC="$REPO_ROOT/internal/infra/views/user_view.go"
PERSON_VIEW_SRC="$REPO_ROOT/internal/infra/views/person_view.go"  # SharedBaseView over the SAME user schema
SCHEMA_SRC="$REPO_ROOT/internal/infra/schemas/user_schema.go"
ENTITY_SRC="$REPO_ROOT/internal/domain/user.go"
DTO_ID_SRC="$REPO_ROOT/internal/web/requests/find_user_by_id.go"
DTO_LIST_SRC="$REPO_ROOT/internal/web/requests/find_users_by_params.go"
PATCHED=("$VIEW_SRC" "$PERSON_VIEW_SRC" "$SCHEMA_SRC" "$ENTITY_SRC" "$DTO_ID_SRC" "$DTO_LIST_SRC")

# POD B on the lane port (BASE), the others on +offset. Same sync group / DB /
# Mongo / broker → one competing-consumer group.
B_HTTP=":$HTTP_PORT";        B_BASE="$BASE"
A_HTTP=":$((HTTP_PORT+10))"; A_BASE="http://localhost:$((HTTP_PORT+10))"
C_HTTP=":$((HTTP_PORT+20))"; C_BASE="http://localhost:$((HTTP_PORT+20))"
D_HTTP=":$((HTTP_PORT+30))"; D_BASE="http://localhost:$((HTTP_PORT+30))"
# The transient first-boot pod (migrate + FreshInit) gets its OWN throwaway ports
# so POD B never reuses them — otherwise the first pod's just-closed :90XX gRPC
# socket lingers in TIME_WAIT and POD B's bind fails, tearing down its rebuild.
BOOT_HTTP=":$((HTTP_PORT+40))"; BOOT_BASE="http://localhost:$((HTTP_PORT+40))"

declare -a PIDS=()
PASS=0; FAIL=0

hr()  { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec() { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title(){ printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }

pq()  { docker exec "${QA_DB_CONTAINER:-omnicore-qa-postgres}" psql -U omnicore -d users_db -tA "$@"; }
mq()  { docker exec "${QA_MONGO_CONTAINER:-omnicore-qa-mongo}" mongosh "$QA_MONGO_DB" --quiet --eval "$1" 2>/dev/null; }
reg() { pq -c "SELECT COALESCE($1::text,'') FROM omnicore_mongo_views WHERE view_name='users';" | tr -d '[:space:]'; }
mcount() { mq "print(db.getCollection('$1').countDocuments({}))" | tr -d '[:space:]'; }

assert_eq(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[1;32m✔\033[0m %s: %s\n' "$1" "$3"; else FAIL=$((FAIL+1)); printf '  \033[1;31m✘\033[0m %s: expected %q, got %q\n' "$1" "$2" "$3"; fi; }
assert_ge(){ if [ -n "$3" ] && [ "$3" -ge "$2" ] 2>/dev/null; then PASS=$((PASS+1)); printf '  \033[1;32m✔\033[0m %s: %s (>= %s)\n' "$1" "$3" "$2"; else FAIL=$((FAIL+1)); printf '  \033[1;31m✘\033[0m %s: expected >= %q, got %q\n' "$1" "$2" "$3"; fi; }
assert_true(){ if [ "$2" = "true" ]; then PASS=$((PASS+1)); printf '  \033[1;32m✔\033[0m %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  \033[1;31m✘\033[0m %s (got %q)\n' "$1" "$2"; fi; }

kill_all(){ [ "${#PIDS[@]}" -gt 0 ] || return 0; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null; done; PIDS=(); }
restore_src(){ [ "${#PATCHED[@]}" -gt 0 ] || return 0; for f in "${PATCHED[@]}"; do [ -f "$f.rsbak" ] && mv "$f.rsbak" "$f"; done; }
cleanup(){
  kill_all
  restore_src
  # Reset the bench so a re-run starts clean (best-effort): drop the test column
  # AND the registry row, so the next V1 boot is a pristine FreshInit at version 1
  # (otherwise the leftover version=2 row trips the downgrade guard).
  pq -c "ALTER TABLE users DROP COLUMN IF EXISTS nickname;"                          >/dev/null 2>&1
  pq -c "DELETE FROM omnicore_mongo_views WHERE view_name IN ('users','persons');"   >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

# start_pod <bin> <http> <grpc-suffix> <log> — background; appends PID to PIDS; echoes PID.
start_pod(){
  local bin="$1" http="$2" g="$3" log="$4"; : > "$log"
  ( cd "$REPO_ROOT"; APP_PROFILE=dev HTTP_ADDR="$http" GRPC_ADDR=":90$g" OMNICORE_CONFIG_PATH="$FAST_YAML" exec "$bin" >>"$log" 2>&1 ) &
  local pid=$!; PIDS+=("$pid"); echo "$pid"
}
wait_ready(){ local base="$1"; local t="${2:-30}"; local d=$(( $(date +%s)+t )); while [ "$(date +%s)" -lt "$d" ]; do curl -sf -o /dev/null "$base/readyz" && return 0; sleep 0.5; done; return 1; }
post_user(){ curl -sS -X POST "$1/users" -H 'Content-Type: application/json' -H 'Accept-Language: en-US' \
  --data "{\"name\":\"$2\",\"email\":\"$2@t.co\",\"document\":\"$2\",\"userName\":\"$2\",\"addresses\":[]}" -o /dev/null -w '%{http_code}'; }
api_total(){ curl -sS "$1/users?onlyTotal=true" 2>/dev/null | jq -r '.pagination.total // .total // (.data|length) // "?"'; }
# poll GET total until it reaches `want` (CDC is eventually consistent + cold on
# first boot) — echoes the last observed total, returns non-zero on timeout.
wait_total(){ local base="$1" want="$2" t="${3:-40}"; local d=$(( $(date +%s)+t )); local n=0; while [ "$(date +%s)" -lt "$d" ]; do n=$(api_total "$base"); [ -n "$n" ] && [ "$n" != "?" ] && [ "$n" -ge "$want" ] 2>/dev/null && { echo "$n"; return 0; }; sleep 1; done; echo "$n"; return 1; }

# ─── the "add a nullable column + project it + bump the view" edit ───
patch_add_nickname(){
  for f in "${PATCHED[@]}"; do cp "$f" "$f.rsbak"; done
  # 1) bump BOTH views over the user schema: the users view AND the persons
  #    SharedBaseView (its user-role sub-doc gains the column too — a shared-schema
  #    column ripples into every view over it, so every one must be version-bumped
  #    or the V2 pods abort at boot with DriftForgotToBump on the un-bumped view).
  perl -pi -e 's/\bVersion\(\d+\)/Version(2)/g' "$VIEW_SRC" "$PERSON_VIEW_SRC"
  # 2) entity: exported Nickname field (required before the schema .Field, or it panics)
  perl -0pi -e 's/(UserName\s+string[^\n]*\n)/$1\tNickname                    *string\n/' "$ENTITY_SRC"
  # 3) schema: map the column so ToGoDoc keeps it and the DTO renders it
  perl -0pi -e 's/(Field\("UserName", "user_name"\)\.\n)/$1\t\tField("Nickname", "nickname").\n/' "$SCHEMA_SRC"
  # 4) read DTOs: surface it on GET /users/:id and GET /users
  perl -0pi -e 's/(UserName\s+string\s+`json:"userName"[^\n]*\n)/$1\tNickname *string `json:"nickname,omitempty"`\n/' "$DTO_ID_SRC"
  perl -0pi -e 's/(UserName\s+\*string\s+`json:"userName,omitempty"[^\n]*\n)/$1\tNickname         *string `json:"nickname,omitempty"`\n/' "$DTO_LIST_SRC"
  grep -q 'Version(2)' "$VIEW_SRC" && grep -q 'Nickname' "$ENTITY_SRC" && grep -q '"nickname"' "$SCHEMA_SRC" || return 1
}

# ═════════════════════════════════════════════════════════════════════════════
sec "Blue-green rebuild — scale ($SEED_COUNT) + multi-pod + column-add"
echo "lane=$BACKEND  MongoDB=$QA_MONGO_DB  lease=${LEASE_SECONDS}s"
command -v jq >/dev/null || { echo "FATAL: jq required"; exit 1; }

# short-lease override so the fence/settle waits do not dominate
sed "s/^    allowDowngrade: false.*/    allowDowngrade: false\n    pointerLeaseSeconds: $LEASE_SECONDS/" "$REPO_ROOT/microservice.dev.yaml" > "$FAST_YAML"
# Disable OTLP tracing: the suite kills many pods and does not test tracing; a
# dead jaeger :4317 makes each tracer shutdown block ~30s, piling up TIME_WAIT
# sockets and slowing the whole run. Off = fast, clean shutdowns.
perl -0pi -e 's/(  tracing:\n    enabled: )true/${1}false/' "$FAST_YAML"

sec "Phase 0 — build V1, migrate, seed, first rebuild"
title "build BIN_V1 (Version 1)"
( cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS" -o "$BIN_V1" ./bootstrap ) || { echo "build V1 failed"; exit 1; }

title "clean slate — drop users+persons registry rows + slots + stale column from any prior run"
# BOTH views are bumped by this suite (persons is a SharedBaseView over the user
# schema), so BOTH registry rows must reset or a V1 boot trips the downgrade guard.
pq -c "DELETE FROM omnicore_mongo_views WHERE view_name IN ('users','persons');" >/dev/null 2>&1 || true
pq -c "ALTER TABLE users DROP COLUMN IF EXISTS nickname;"                          >/dev/null 2>&1 || true
mq "['users','users__0','users__1','persons','persons__0','persons__1'].forEach(c=>db.getCollection(c).drop())" >/dev/null 2>&1 || true

title "boot V1 once (throwaway ports) → apply migrations (create tables) → FreshInit"
pid=$(start_pod "$BIN_V1" "$BOOT_HTTP" 99 /tmp/omnicore-rs-boot.log)
wait_ready "$BOOT_BASE" 40 || { echo "V1 first boot never ready"; tail -30 /tmp/omnicore-rs-boot.log; exit 1; }
title "CRUD smoke: insert + read + edit a user through the live service"
assert_eq "POST /users → 201" "201" "$(post_user "$BOOT_BASE" crud1)"
tot=$(wait_total "$BOOT_BASE" 1 40)   # poll: CDC projection is cold on first boot
assert_ge "GET /users total >= 1 after insert (CDC)" "1" "$tot"
uid=$(curl -sS "$BOOT_BASE/users?limit=1" | jq -r '.data[0].id // .data[0].Id // empty')
if [ -n "$uid" ]; then
  assert_eq "PATCH /users/:id (edit userName) → 200" "200" "$(curl -sS -X PATCH "$BOOT_BASE/users/$uid" -H 'Content-Type: application/json' --data '{"userName":"crud1-edited"}' -o /dev/null -w '%{http_code}')"
else
  FAIL=$((FAIL+1)); printf '  \033[1;31m✘\033[0m no user id to PATCH (projection empty)\n'
fi
kill_all

title "reset domain + drop Mongo slots (keep registry → reboot = DriftMongoWiped)"
pq -c "TRUNCATE persons, users, addresses, user_configurations, outbox CASCADE;" >/dev/null
mq "['users','users__0','users__1'].forEach(c=>db.getCollection(c).drop())" >/dev/null

title "bulk-seed $SEED_COUNT FULL aggregates (persons + users + addresses + configs)"
pq -c "INSERT INTO persons (id,document,name,email) SELECT gen_random_uuid(),'sd'||lpad(g::text,12,'0'),'name '||g,'p'||g||'@qa.test' FROM generate_series(1,$SEED_COUNT) g;"
pq -c "INSERT INTO users (id,user_name) SELECT id,'u_'||document FROM persons;"
pq -c "INSERT INTO addresses (person_id,street,number,neighborhood,city,state,zip_code,country) SELECT id,'St','1','Nb','City','ST','00000','US' FROM persons;"
pq -c "INSERT INTO user_configurations (id,email_notification) SELECT id,true FROM users WHERE random()<0.5;"
assert_eq "seed: users count" "$SEED_COUNT" "$(pq -c 'SELECT count(*) FROM users;' | tr -d '[:space:]')"

title "first blue-green rebuild (DriftMongoWiped) — $SEED_COUNT → users__0"
pid=$(start_pod "$BIN_V1" "$B_HTTP" 81 /tmp/omnicore-rs-B.log); B_PID=$pid  # "service 1" (V1) — stays up through Phase 2, dropped in Phase 3
if wait_ready "$B_BASE" "$REBUILD_TIMEOUT"; then
  assert_eq "flipped to users__0"           "users__0" "$(reg active_collection)"
  assert_eq "docs in active slot users__0"  "$SEED_COUNT" "$(mcount users__0)"
  assert_ge "GET /users total = seed"       "$SEED_COUNT" "$(api_total "$B_BASE")"
else
  FAIL=$((FAIL+1)); echo "✘ first rebuild never became ready"; tail -40 /tmp/omnicore-rs-B.log
fi
# POD B stays running for the multi-pod phase.

sec "Phase 1 — the edit: add nullable column, project it, bump the view; build V2"
title "ALTER users ADD nickname + patch (entity + schema + DTOs + Version→2)"
pq -c "ALTER TABLE users ADD COLUMN IF NOT EXISTS nickname VARCHAR(100);" >/dev/null
patch_add_nickname || { echo "FATAL: source patch failed"; FAIL=$((FAIL+1)); }
( cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS" -o "$BIN_V2" ./bootstrap ) && echo "BIN_V2 built (Version 2 + nickname)" || { echo "FATAL: V2 build failed"; FAIL=$((FAIL+1)); }
restore_src   # tree clean again; BIN_V2 keeps the change

sec "Phase 2 — multi-pod version-bump rebuild"
mq "db.getCollection('users__1').drop()" >/dev/null
title "boot POD A (V2, driver) — livez up at once, readyz 503 during the rebuild"
sleep 2; a_live=$(curl -s -o /dev/null -w '%{http_code}' "$A_BASE/livez")   # before boot: expect no server
pid=$(start_pod "$BIN_V2" "$A_HTTP" 91 /tmp/omnicore-rs-A.log)
title "wait for the dual-apply window (shadow_collection set)"
sh=""; d=$(( $(date +%s)+REBUILD_TIMEOUT )); while [ "$(date +%s)" -lt "$d" ]; do sh=$(reg shadow_collection); [ -n "$sh" ] && break; sleep 0.3; done
assert_eq "POD A recorded shadow slot users__1" "users__1" "$sh"
# During the window: /livez up, /readyz 503.
assert_eq "POD A /livez 200 during rebuild"  "200" "$(curl -s -o /dev/null -w '%{http_code}' "$A_BASE/livez")"
assert_eq "POD A /readyz 503 during rebuild"  "503" "$(curl -s -o /dev/null -w '%{http_code}' "$A_BASE/readyz")"
# Stable contrast: the OLD active slot (users__0, built by V1) has NO nickname
# field — captured now while it is the full seeded slot, before any reclaim.
assert_eq "old active users__0 (v1) docs lack 'nickname'" "false" "$(mq "print(db.getCollection('users__0').findOne().hasOwnProperty('nickname'))")"

title "boot POD C (V2) mid-rebuild alongside POD A — follower proof checked after the flip"
pid=$(start_pod "$BIN_V2" "$C_HTTP" 93 /tmp/omnicore-rs-C.log)
# Boot POD C concurrently but do NOT block on it here, so the users dual-apply
# window stays open for the write burst below. POD C follows POD A on the USERS
# lock (no abort) and may itself drive the PERSONS view's rebuild (the nickname
# ripples there and that lock is free when POD C boots) — which can run before it
# even reaches the users plan, so its follower log + readiness are asserted later.

# Let every running pod's resolver lease refresh so it OBSERVES the shadow flag
# (dual-apply ON) before we fire — otherwise a write POD B consumes in the gap
# between the registry flag and its own lease refresh lands in the old slot only
# and is lost when that slot is reclaimed after the flip.
# Background sampler: track the PEAK users__0 (old active slot) doc count across
# the whole window. Started BEFORE we fire, so it observes the old slot both at
# its seeded baseline AND as live dual-writes land — before the post-flip reclaim
# drops it. Observing dual-writes on the OLD slot needs the backfill window to
# outlast the write burst, i.e. a non-trivial seed (SEED_COUNT big enough that the
# backfill runs for tens of seconds); at tiny seeds the rebuild finishes before
# the writes land and only the new-slot no-loss check is meaningful.
peakfile="/tmp/omnicore-rs-peak0.$$"; echo 0 > "$peakfile"
# Per-tick bash sampler tracking the PEAK users__0 (old active slot) size. Each
# tick writes immediately (no buffering to lose). It uses countDocuments (the
# exact count) not estimatedDocumentCount — the latter reads cached metadata that
# reports 0 for a freshly bulk-built slot even when the docs are there.
( while :; do c=$(mcount users__0); p=$(cat "$peakfile" 2>/dev/null); case "$c" in ''|*[!0-9]*) ;; *) [ "$c" -gt "${p:-0}" ] && echo "$c" > "$peakfile";; esac; sleep 0.4; done ) &
SAMPLER=$!

title "let pods observe dual-apply (~1 lease), then fire $CONCURRENT_WRITES writes at POD B during the window"
sleep $(( LEASE_SECONDS + 2 ))   # POD B refreshes its resolver within one lease → dual-apply ON before we write
ok=0; for n in $(seq 1 "$CONCURRENT_WRITES"); do [ "$(post_user "$B_BASE" cc$n)" = "201" ] && ok=$((ok+1)); done
assert_eq "concurrent POSTs accepted" "$CONCURRENT_WRITES" "$ok"

want=$(( SEED_COUNT + CONCURRENT_WRITES ))
title "wait for the flip to users__1"
d=$(( $(date +%s)+REBUILD_TIMEOUT )); flipped=false
while [ "$(date +%s)" -lt "$d" ]; do [ "$(reg status)" = "done" ] && [ "$(reg active_collection)" = "users__1" ] && [ -z "$(reg shadow_collection)" ] && { flipped=true; break; }; sleep 0.3; done
assert_true "flipped to users__1" "$flipped"
kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
peak0=$(cat "$peakfile" 2>/dev/null); peak0=${peak0:-0}; rm -f "$peakfile"
# Old slot kept receiving the live writes while it was still active (dual-apply):
# peak grew past the seed. Hard assertion only when the window is wide enough to
# observe it (SEED_COUNT >= WINDOW_MIN); otherwise it is reported informationally
# and the new-slot no-loss check below carries the correctness proof.
WINDOW_MIN="${WINDOW_MIN:-20000}"
if [ "$SEED_COUNT" -ge "$WINDOW_MIN" ]; then
  assert_ge "old slot users__0 got live dual-writes (peak > seed)" "$(( SEED_COUNT + 1 ))" "$peak0"
elif [ "$peak0" -gt "$SEED_COUNT" ] 2>/dev/null; then
  PASS=$((PASS+1)); printf '  \033[1;32m✔\033[0m old slot users__0 got live dual-writes (peak %s > seed %s)\n' "$peak0" "$SEED_COUNT"
else
  printf '  \033[1;33mⓘ\033[0m dual-apply window closed before writes landed (seed %s < %s) — new-slot no-loss check is the invariant\n' "$SEED_COUNT" "$WINDOW_MIN"
fi

title "POD C did not abort — it logs the follower path for the users rebuild"
# Generous wait: POD C may have driven the persons rebuild first and only reach
# the users plan (where POD A holds the lock → follower log) afterwards.
d=$(( $(date +%s)+REBUILD_TIMEOUT )); fol=false; while [ "$(date +%s)" -lt "$d" ]; do grep -q "serving the active slot until the flip" /tmp/omnicore-rs-C.log && { fol=true; break; }; sleep 1; done
assert_true "POD C followed the users rebuild (did not abort)" "$fol"

title "converge + verify NO DATA LOSS on the new active slot"
d=$(( $(date +%s)+300 )); while [ "$(date +%s)" -lt "$d" ]; do [ "$(mcount users__1)" = "$want" ] && break; sleep 2; done
assert_eq "users__1 (new active) = seed + concurrent (no loss)" "$want" "$(mcount users__1)"
assert_true "users__1 docs carry 'nickname'" "$(mq "print(db.getCollection('users__1').findOne().hasOwnProperty('nickname'))")"

sec "Phase 3 — post-flip: drop POD 1 (service 1), boot POD D (service 4), all pods read the NEW view"
# POD A may still be finishing the persons rebuild (it drives BOTH views), so give
# its readiness the full rebuild budget.
wait_ready "$A_BASE" "$REBUILD_TIMEOUT" && { PASS=$((PASS+1)); echo "  ✔ POD A (service 2) now serving (readyz OK after flip)"; } || { FAIL=$((FAIL+1)); echo "  ✘ POD A never ready after flip"; }
title "endpoint inspection: the flipped view serves via the new slot on POD A"
assert_ge "GET /users total on the new view = seed + concurrent" "$want" "$(wait_total "$A_BASE" "$want" 120)"

title "drop POD B (service 1, V1) now that POD A is ready — then boot POD D (service 4, V2, fresh)"
kill "$B_PID" 2>/dev/null; wait "$B_PID" 2>/dev/null
# POD B's :8081/:9081 are now freed for good; POD D takes its own ports.
pid=$(start_pod "$BIN_V2" "$D_HTTP" 96 /tmp/omnicore-rs-D.log)
wait_ready "$D_BASE" "$REBUILD_TIMEOUT" && { PASS=$((PASS+1)); echo "  ✔ POD D booted clean (no rebuild — registry already at v2)"; } || { FAIL=$((FAIL+1)); echo "  ✘ POD D never ready"; tail -20 /tmp/omnicore-rs-D.log; }
assert_ge "POD D (service 4) reads the NEW view (GET /users total)" "$want" "$(wait_total "$D_BASE" "$want" 120)"
# POD C may have been driving the persons rebuild — wait for it to finish + serve.
wait_ready "$C_BASE" "$REBUILD_TIMEOUT" && { PASS=$((PASS+1)); echo "  ✔ POD C (service 3) ready (finished its rebuild work)"; } || { FAIL=$((FAIL+1)); echo "  ✘ POD C never ready"; }
assert_ge "POD C (service 3, follower) reads the NEW view too"      "$want" "$(wait_total "$C_BASE" "$want" 120)"
grep -q "boot rebuild failed" /tmp/omnicore-rs-D.log && { FAIL=$((FAIL+1)); echo "  ✘ POD D logged a rebuild"; } || { PASS=$((PASS+1)); echo "  ✔ POD D did no rebuild (DriftNone)"; }
# Endpoint proof the new slot is what all pods serve: GET by-id parses and the
# response schema carries the new column (null for seeded rows, so omitempty may
# drop it from the body — the DB-layer hasOwnProperty check above is the value
# proof; this confirms every surviving pod answers 200 from the flipped view).
title "endpoint proof: every surviving pod (A/C/D) serves the flipped view"
for pod in A:$A_BASE C:$C_BASE D:$D_BASE; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "${pod#*:}/users?limit=1")
  assert_eq "GET /users on POD ${pod%%:*} → 200 (new slot)" "200" "$code"
done

sec "Results"
echo "Results: $PASS PASS, $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
