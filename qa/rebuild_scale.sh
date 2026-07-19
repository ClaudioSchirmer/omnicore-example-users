#!/usr/bin/env bash
# rebuild_scale.sh — online blue-green view rebuild under LOAD + full MULTI-POD.
#
# Heavy suite that proves the whole blue-green story end to end on a large FULL
# aggregate:
#   • CRUD works on a live service (insert + edit + read),
#   • a version-bump rebuild that ADDS A NULLABLE COLUMN to the view runs online,
#   • a second pod (POD A, the driver) rebuilds while POD B keeps serving,
#   • a third pod (POD C) that boots mid-rebuild becomes a FOLLOWER (livez 200,
#     readyz 200 — it does NOT abort; it serves the active slot until the flip),
#   • writes fired during the rebuild DUAL-WRITE into BOTH the new and old slots,
#   • after the flip a fresh pod (POD D) and POD A/C read the NEW view,
#   • zero data loss, inspected via BOTH the database AND the HTTP endpoints.
#
# LANE-DRIVEN like every other qa suite: `BACKEND=postgres|mysql|sqlserver|oracle`
# selects the whole leg (engine + transport + relay + Mongo DB + ports) via
# _backend.sh; the bulk seed is dialect-aware (row generator + id type differ).
# It runs in the qa/run.sh matrix as a SERIAL suite (it patches the shared source
# tree + rebuilds, so it cannot run concurrent with another lane's build), one
# lane at a time with SEED_COUNT=100000; run.sh SKIPs a lane whose infra is down.
#
# The service source is patched (entity + schema + read DTOs + BOTH views' Version)
# and a nullable `nickname` column added; a cleanup trap restores the tree, drops
# the column + registry rows, and wipes the seeded domain on every exit path.
#
# Prerequisites (the lane's bench up + relay registered) — qa/run.sh does this; by
# hand, e.g. the postgres lane:
#   docker compose -f devops/docker-compose.yml up -d postgres mongo kafka connect redis --wait
#   ./devops/debezium/register-connector.sh postgres
#
# Run:   BACKEND=postgres bash qa/rebuild_scale.sh
# Tune:  SEED_COUNT=1000000 CONCURRENT_WRITES=200 LEASE_SECONDS=2 BACKEND=mysql bash qa/rebuild_scale.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BACKEND="${BACKEND:-postgres}"     # inherited from run.sh; defaults to lane A standalone
source "$REPO_ROOT/qa/_backend.sh"

SEED_COUNT="${SEED_COUNT:-1000000}"
CONCURRENT_WRITES="${CONCURRENT_WRITES:-200}"
LEASE_SECONDS="${LEASE_SECONDS:-2}"          # pointerLeaseSeconds override — keeps fence waits short
REBUILD_TIMEOUT="${REBUILD_TIMEOUT:-3600}"   # a 1M full-aggregate backfill takes minutes
WINDOW_MIN="${WINDOW_MIN:-50000}"            # below this the (set-based, fast) backfill flips before the live writes land — too short to observe the old-slot dual-writes; the new-slot no-loss check still runs at every seed
SMOKE_CDC_TIMEOUT="${SMOKE_CDC_TIMEOUT:-120}" # first-boot read-back poll — generous for a cold relay (Oracle LogMiner floors at seconds)

BIN_V1="/tmp/omnicore-rs-v1-$BACKEND"
BIN_V2="/tmp/omnicore-rs-v2-$BACKEND"
FAST_YAML="/tmp/omnicore-rs-fast-$BACKEND.yaml"

# Files the "add a nullable column, project it, bump the view" edit patches.
VIEW_SRC="$REPO_ROOT/internal/infra/views/user_view.go"
PERSON_VIEW_SRC="$REPO_ROOT/internal/infra/views/person_view.go"  # SharedBaseView over the SAME user schema
SCHEMA_SRC="$REPO_ROOT/internal/infra/schemas/user_schema.go"
ENTITY_SRC="$REPO_ROOT/internal/domain/user.go"
DTO_ID_SRC="$REPO_ROOT/internal/web/requests/find_user_by_id.go"
DTO_LIST_SRC="$REPO_ROOT/internal/web/requests/find_users_by_params.go"
PATCHED=("$VIEW_SRC" "$PERSON_VIEW_SRC" "$SCHEMA_SRC" "$ENTITY_SRC" "$DTO_ID_SRC" "$DTO_LIST_SRC")

# POD B on the lane ports (BASE / GRPC_PORT), the others on +offset. Same sync
# group / DB / Mongo / broker → one competing-consumer group. run.sh runs this
# suite serially per lane, so only one lane's pods are ever up at a time.
B_HTTP=":$HTTP_PORT";           B_BASE="$BASE";                                B_GRPC="$GRPC_PORT"
A_HTTP=":$((HTTP_PORT+10))";    A_BASE="http://localhost:$((HTTP_PORT+10))";   A_GRPC="$((GRPC_PORT+10))"
C_HTTP=":$((HTTP_PORT+20))";    C_BASE="http://localhost:$((HTTP_PORT+20))";   C_GRPC="$((GRPC_PORT+20))"
D_HTTP=":$((HTTP_PORT+30))";    D_BASE="http://localhost:$((HTTP_PORT+30))";   D_GRPC="$((GRPC_PORT+30))"
# The transient first-boot pod (migrate + FreshInit) gets its OWN throwaway ports
# so POD B never reuses them — otherwise the first pod's just-closed gRPC socket
# lingers in TIME_WAIT and POD B's bind fails, tearing down its rebuild.
BOOT_HTTP=":$((HTTP_PORT+40))"; BOOT_BASE="http://localhost:$((HTTP_PORT+40))"; BOOT_GRPC="$((GRPC_PORT+40))"

declare -a PIDS=()
PASS=0; FAIL=0

hr()  { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec() { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title(){ printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }

# DB access is lane-aware (qa_db_query / qa_db_exec from _backend.sh); the Mongo
# read side lives in one container, isolated per lane by DB name (QA_MONGO_DB).
mq()  { docker exec "${QA_MONGO_CONTAINER:-omnicore-qa-mongo}" mongosh "$QA_MONGO_DB" --quiet --eval "$1" 2>/dev/null; }
reg() { qa_db_query "SELECT COALESCE($1,'') FROM omnicore_mongo_views WHERE view_name='users'" | tr -d '[:space:]'; }
mcount() { mq "print(db.getCollection('$1').countDocuments({}))" | tr -d '[:space:]'; }

assert_eq(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[1;32m✔\033[0m %s: %s\n' "$1" "$3"; else FAIL=$((FAIL+1)); printf '  \033[1;31m✘\033[0m %s: expected %q, got %q\n' "$1" "$2" "$3"; fi; }
assert_ge(){ if [ -n "$3" ] && [ "$3" -ge "$2" ] 2>/dev/null; then PASS=$((PASS+1)); printf '  \033[1;32m✔\033[0m %s: %s (>= %s)\n' "$1" "$3" "$2"; else FAIL=$((FAIL+1)); printf '  \033[1;31m✘\033[0m %s: expected >= %q, got %q\n' "$1" "$2" "$3"; fi; }
assert_true(){ if [ "$2" = "true" ]; then PASS=$((PASS+1)); printf '  \033[1;32m✔\033[0m %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  \033[1;31m✘\033[0m %s (got %q)\n' "$1" "$2"; fi; }

# ── dialect-aware DDL/DML the lane helpers do not cover ──────────────────────
add_nickname_col(){
  case "$REL_DIALECT" in
    postgres)  qa_db_exec "ALTER TABLE users ADD COLUMN IF NOT EXISTS nickname VARCHAR(100)" ;;
    mysql)     qa_db_exec "ALTER TABLE users ADD COLUMN nickname VARCHAR(100)" ;;
    sqlserver) qa_db_exec "ALTER TABLE users ADD nickname VARCHAR(100)" ;;
    oracle)    qa_db_exec "ALTER TABLE users ADD nickname VARCHAR2(100)" ;;
  esac
}
drop_nickname_col(){   # best-effort — tolerate "column does not exist"
  case "$REL_DIALECT" in
    postgres) qa_db_exec "ALTER TABLE users DROP COLUMN IF EXISTS nickname" 2>/dev/null || true ;;
    *)        qa_db_exec "ALTER TABLE users DROP COLUMN nickname"           2>/dev/null || true ;;
  esac
}
reset_registry(){ qa_db_exec "DELETE FROM omnicore_mongo_views WHERE view_name IN ('users','persons')" 2>/dev/null || true; }
drop_mongo_slots(){ mq "['users','users__0','users__1','persons','persons__0','persons__1'].forEach(c=>db.getCollection(c).drop())" >/dev/null 2>&1 || true; }

# Bulk-seed N full aggregates (persons + users + addresses + user_configurations)
# via raw SQL — the rebuild backfill reads the relational source directly, and the
# API would be orders of magnitude too slow at this scale. The row generator and
# the id type diverge per dialect; the column names are identical everywhere.
seed_aggregates(){
  local n="$1" D V
  case "$REL_DIALECT" in
    postgres)
      qa_db_exec "INSERT INTO persons (id,document,name,email) SELECT gen_random_uuid(),'sd'||g,'name '||g,'p'||g||'@qa.test' FROM generate_series(1,$n) g"
      qa_db_exec "INSERT INTO users (id,user_name) SELECT id,'u_'||document FROM persons"
      qa_db_exec "INSERT INTO addresses (person_id,street,number,neighborhood,city,state,zip_code,country) SELECT id,'St','1','Nb','City','ST','00000','US' FROM persons"
      qa_db_exec "INSERT INTO user_configurations (id,email_notification) SELECT id,$QA_SQL_TRUE FROM users WHERE random()<0.5"
      ;;
    mysql)
      # numbers 1..1e6 via a cross-join of six inline digit tables, filtered to n.
      D="(SELECT 0 i UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)"
      qa_db_exec "INSERT INTO persons (id,document,name,email) SELECT UUID_TO_BIN(UUID(),0),CONCAT('sd',g),CONCAT('name ',g),CONCAT('p',g,'@qa.test') FROM (SELECT t6.i*100000+t5.i*10000+t4.i*1000+t3.i*100+t2.i*10+t1.i+1 g FROM $D t1,$D t2,$D t3,$D t4,$D t5,$D t6) nums WHERE g<=$n"
      qa_db_exec "INSERT INTO users (id,user_name) SELECT id,CONCAT('u_',document) FROM persons"
      qa_db_exec "INSERT INTO addresses (id,person_id,street,number,neighborhood,city,state,zip_code,country) SELECT UUID_TO_BIN(UUID(),0),id,'St','1','Nb','City','ST','00000','US' FROM persons"
      qa_db_exec "INSERT INTO user_configurations (id,email_notification) SELECT id,$QA_SQL_TRUE FROM users WHERE RAND()<0.5"
      ;;
    sqlserver)
      V="(VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9))"
      qa_db_exec "INSERT INTO persons (id,document,name,email) SELECT CONVERT(BINARY(16),REPLACE(CONVERT(char(36),NEWID()),'-',''),2),'sd'+CAST(g AS varchar(20)),'name '+CAST(g AS varchar(20)),'p'+CAST(g AS varchar(20))+'@qa.test' FROM (SELECT t6.i*100000+t5.i*10000+t4.i*1000+t3.i*100+t2.i*10+t1.i+1 g FROM $V t1(i) CROSS JOIN $V t2(i) CROSS JOIN $V t3(i) CROSS JOIN $V t4(i) CROSS JOIN $V t5(i) CROSS JOIN $V t6(i)) nums WHERE g<=$n"
      qa_db_exec "INSERT INTO users (id,user_name) SELECT id,'u_'+document FROM persons"
      qa_db_exec "INSERT INTO addresses (id,person_id,street,number,neighborhood,city,state,zip_code,country) SELECT CONVERT(BINARY(16),REPLACE(CONVERT(char(36),NEWID()),'-',''),2),id,'St','1','Nb','City','ST','00000','US' FROM persons"
      qa_db_exec "INSERT INTO user_configurations (id,email_notification) SELECT id,$QA_SQL_TRUE FROM users WHERE ABS(CHECKSUM(NEWID()))%2=0"
      ;;
    oracle)
      qa_db_exec "INSERT INTO persons (id,document,name,email) SELECT SYS_GUID(),'sd'||g,'name '||g,'p'||g||'@qa.test' FROM (SELECT LEVEL g FROM dual CONNECT BY LEVEL<=$n)"
      qa_db_exec "INSERT INTO users (id,user_name) SELECT id,'u_'||document FROM persons"
      qa_db_exec "INSERT INTO addresses (id,person_id,street,number,neighborhood,city,state,zip_code,country) SELECT SYS_GUID(),id,'St','1','Nb','City','ST','00000','US' FROM persons"
      qa_db_exec "INSERT INTO user_configurations (id,email_notification) SELECT id,$QA_SQL_TRUE FROM users WHERE DBMS_RANDOM.VALUE<0.5"
      ;;
  esac
}

kill_all(){ [ "${#PIDS[@]}" -gt 0 ] || return 0; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null; done; PIDS=(); }
restore_src(){ [ "${#PATCHED[@]}" -gt 0 ] || return 0; for f in "${PATCHED[@]}"; do [ -f "$f.rsbak" ] && mv "$f.rsbak" "$f"; done; }
cleanup(){
  kill_all
  restore_src
  # Leave the lane's bench pristine for the next run / the next serial suite:
  # drop the test column + the bumped registry rows (else a v1 boot trips the
  # downgrade guard) and wipe the seeded domain (else the next suite inherits
  # 100k+ leftover rows). All best-effort — the DB may already be down on abort.
  drop_nickname_col
  reset_registry
  qa_db_reset_domain 2>/dev/null || true
  drop_mongo_slots
}
trap cleanup EXIT INT TERM

# start_pod <bin> <http-addr> <grpc-port> <log> — background; appends PID to PIDS; echoes PID.
start_pod(){
  local bin="$1" http="$2" g="$3" log="$4"; : > "$log"
  ( cd "$REPO_ROOT"; APP_PROFILE=dev HTTP_ADDR="$http" GRPC_ADDR=":$g" OMNICORE_CONFIG_PATH="$FAST_YAML" exec "$bin" >>"$log" 2>&1 ) &
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
echo "lane=$BACKEND ($REL_DIALECT)  MongoDB=$QA_MONGO_DB  lease=${LEASE_SECONDS}s"
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
reset_registry
drop_nickname_col
drop_mongo_slots

title "boot V1 once (throwaway ports) → apply migrations (create tables) → FreshInit"
pid=$(start_pod "$BIN_V1" "$BOOT_HTTP" "$BOOT_GRPC" /tmp/omnicore-rs-boot.log)
wait_ready "$BOOT_BASE" 60 || { echo "V1 first boot never ready"; tail -30 /tmp/omnicore-rs-boot.log; exit 1; }
title "CRUD smoke: insert + edit + read a user through the live service"
assert_eq "POST /users → 201" "201" "$(post_user "$BOOT_BASE" crud1)"
# PATCH by the DB id, NOT the projection — the edit is a synchronous write and must
# not wait on the eventually-consistent read side (slow on Oracle LogMiner).
uid=$(qa_db_query "SELECT $QA_SQL_TOP1 $(qa_uuid_select id) FROM users $QA_SQL_LIMIT1" | tr -d '[:space:]')
if [ -n "$uid" ]; then
  assert_eq "PATCH /users/:id (edit userName) → 200" "200" "$(curl -sS -X PATCH "$BOOT_BASE/users/$uid" -H 'Content-Type: application/json' --data '{"userName":"crud1-edited"}' -o /dev/null -w '%{http_code}')"
else
  FAIL=$((FAIL+1)); printf '  \033[1;31m✘\033[0m no user id in the DB to PATCH\n'
fi
# Read-back through the projection is the only CDC-dependent smoke check — poll it
# generously (a cold relay's first event is slow, Oracle LogMiner most of all).
tot=$(wait_total "$BOOT_BASE" 1 "$SMOKE_CDC_TIMEOUT")
assert_ge "GET /users total >= 1 after insert (CDC)" "1" "$tot"
kill_all

title "reset domain + drop Mongo slots (keep registry → reboot = DriftMongoWiped)"
qa_db_reset_domain
mq "['users','users__0','users__1'].forEach(c=>db.getCollection(c).drop())" >/dev/null

title "bulk-seed $SEED_COUNT FULL aggregates (persons + users + addresses + configs)"
seed_aggregates "$SEED_COUNT"
assert_eq "seed: users count" "$SEED_COUNT" "$(qa_db_query 'SELECT count(*) FROM users' | tr -d '[:space:]')"

title "first blue-green rebuild (DriftMongoWiped) — $SEED_COUNT → users__0"
pid=$(start_pod "$BIN_V1" "$B_HTTP" "$B_GRPC" /tmp/omnicore-rs-B.log); B_PID=$pid  # "service 1" (V1) — stays up through Phase 2, dropped in Phase 3
if wait_ready "$B_BASE" "$REBUILD_TIMEOUT"; then
  assert_eq "flipped to users__0"           "users__0" "$(reg active_collection)"
  assert_eq "docs in active slot users__0"  "$SEED_COUNT" "$(mcount users__0)"
  assert_ge "GET /users total = seed"       "$SEED_COUNT" "$(api_total "$B_BASE")"
  # Performance yardstick: the pure backfill time for $SEED_COUNT full aggregates
  # (recompose from the relational source → bulk Mongo upsert), directly
  # comparable across engines at equal N. Printed, not asserted.
  bd_ns=$(grep -aoE '"view":"users"[^}]*"duration":[0-9]+' /tmp/omnicore-rs-B.log 2>/dev/null | grep -oE 'duration":[0-9]+' | head -1 | sed 's/duration"://')
  [ -n "$bd_ns" ] && awk -v ns="$bd_ns" -v n="$SEED_COUNT" -v e="$REL_DIALECT" 'BEGIN{printf "  \033[1;36m⏱ PERF\033[0m first-rebuild backfill: %.2fs for %s aggregates on %s (%.0f/s)\n", ns/1e9, n, e, n/(ns/1e9)}'
else
  FAIL=$((FAIL+1)); echo "✘ first rebuild never became ready"; tail -40 /tmp/omnicore-rs-B.log
fi
# POD B stays running for the multi-pod phase.

sec "Phase 1 — the edit: add nullable column, project it, bump the view; build V2"
title "ALTER users ADD nickname + patch (entity + schema + DTOs + Version→2)"
add_nickname_col
patch_add_nickname || { echo "FATAL: source patch failed"; FAIL=$((FAIL+1)); }
( cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS" -o "$BIN_V2" ./bootstrap ) && echo "BIN_V2 built (Version 2 + nickname)" || { echo "FATAL: V2 build failed"; FAIL=$((FAIL+1)); }
restore_src   # tree clean again; BIN_V2 keeps the change

sec "Phase 2 — multi-pod version-bump rebuild"
mq "db.getCollection('users__1').drop()" >/dev/null
title "boot POD A (V2, driver) — livez up at once, readyz 503 during the rebuild"
sleep 2; a_live=$(curl -s -o /dev/null -w '%{http_code}' "$A_BASE/livez")   # before boot: expect no server
pid=$(start_pod "$BIN_V2" "$A_HTTP" "$A_GRPC" /tmp/omnicore-rs-A.log)
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
pid=$(start_pod "$BIN_V2" "$C_HTTP" "$C_GRPC" /tmp/omnicore-rs-C.log)
# Boot POD C concurrently but do NOT block on it here, so the users dual-apply
# window stays open for the write burst below. POD C follows POD A on the USERS
# lock (no abort) and may itself drive the PERSONS view's rebuild (the nickname
# ripples there and that lock is free when POD C boots) — which can run before it
# even reaches the users plan, so its follower log + readiness are asserted later.

# Background sampler: track the PEAK users__0 (old active slot) doc count across
# the whole window. Started BEFORE we fire, so it observes the old slot both at
# its seeded baseline AND as live dual-writes land — before the post-flip reclaim
# drops it. Observing dual-writes on the OLD slot needs the backfill window to
# outlast the write burst, i.e. a non-trivial seed (SEED_COUNT big enough that the
# backfill runs for tens of seconds); at tiny seeds the rebuild finishes before
# the writes land and only the new-slot no-loss check is meaningful.
peakfile="/tmp/omnicore-rs-peak0.$$"; echo 0 > "$peakfile"
# Per-tick bash sampler: each tick writes immediately (no buffering to lose), and
# uses countDocuments (the exact count) not estimatedDocumentCount — the latter
# reads cached metadata that reports 0 for a freshly bulk-built slot.
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
# observe it (SEED_COUNT >= WINDOW_MIN); otherwise report it informationally and
# let the new-slot no-loss check below carry the correctness proof.
# Hard on the fast-CDC backends (they observe the writes land in the old slot
# during the window). On Oracle the LogMiner floor (~2-3s) means live writes often
# arrive AFTER the fast SQL backfill has already flipped — the old slot is retired
# before they reach it, so there is legitimately nothing to observe there (the
# new-slot no-loss check below still proves they were not lost). So: hard when the
# window is wide (seed >= WINDOW_MIN) AND the backend's CDC is fast; otherwise
# report what was seen informationally.
if [ "$peak0" -gt "$SEED_COUNT" ] 2>/dev/null; then
  PASS=$((PASS+1)); printf '  \033[1;32m✔\033[0m old slot users__0 got live dual-writes (peak %s > seed %s)\n' "$peak0" "$SEED_COUNT"
elif [ "$SEED_COUNT" -ge "$WINDOW_MIN" ] && [ "$REL_DIALECT" != "oracle" ]; then
  assert_ge "old slot users__0 got live dual-writes (peak > seed)" "$(( SEED_COUNT + 1 ))" "$peak0"
else
  printf '  \033[1;33mⓘ\033[0m dual-apply window closed before the live writes landed on the old slot (seed=%s, %s CDC) — new-slot no-loss check is the invariant\n' "$SEED_COUNT" "$REL_DIALECT"
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
# POD B's ports are now freed for good; POD D takes its own ports.
pid=$(start_pod "$BIN_V2" "$D_HTTP" "$D_GRPC" /tmp/omnicore-rs-D.log)
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
