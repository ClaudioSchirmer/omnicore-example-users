#!/usr/bin/env bash
# qa/auth_selfissued.sh — end-to-end proof of web/authcore.Issuer (the
# framework's self-issuance capability) via the QA-only /qa/auth/* showcase
# (internal/web/qafixtures/auth_routes.go), covering the FULL surface in one
# run:
#
#   A. Happy path — login mints access+refresh via the real Issuer, whoami
#      validates the self-issued token through the SAME service's unmodified
#      auth.jwt Validator (zero issuer-specific code), permission granted vs
#      denied (the "permissions" claim round-trips through TokenRequest.Claims).
#   B. Token edge cases — no token, forged/garbage, expired (real TTL wait),
#      wrong aud, unknown kid (different never-published key) — all via
#      hand-minted RS256 tokens (openssl, the SAME pattern grpc_security.sh
#      uses) so the VALIDATOR's rejections are proven independent of the
#      Issuer's own happy-path minting.
#   C. Refresh rotation — redeem rotates (old value dead after first use),
#      claims are RE-SUPPLIED fresh at redemption time (not frozen from
#      login), and reuse of an already-redeemed value revokes the WHOLE
#      family — including the newest, otherwise-still-valid rotated token.
#   D. Explicit revoke — /qa/auth/logout resolves a refresh token's family
#      (hashing it exactly like the Issuer does) and revokes it directly via
#      authcore.RefreshTokenStore.RevokeFamily.
#   E. Access-token revoke — /qa/auth/revoke-access denylists a live,
#      cryptographically-still-valid access token's jti through the
#      in-process authcore.TokenChecker seam (Wiring.TokenChecker), backed by
#      Deps.SharedCache (a real Redis, the lane's own).
#   F. JWKS document — every published kid present, NO private key material
#      (d/p/q/dp/dq/qi) ever appears in the response.
#   G. Key rotation — reboot with a SECOND key promoted to current and the
#      first demoted to previous: a token hand-signed with the now-previous
#      key still validates (publish-then-sign / previous-still-valid), and a
#      fresh login signs with the new current key.
#   H. Runtime TTL retuning — the Issuer's Set/Get TTL seam over /qa/auth/ttl:
#      each setter's effect proven on the NEXT minted token (default lifetime,
#      the ceiling capping a per-request TokenRequest.TTL, the refresh
#      lifetime), every rejection the setters owe (non-positive, default above
#      the ceiling, ceiling below the default, and 0 on the ceiling — which
#      must NOT mean "unbounded") leaving state untouched, and a reboot
#      restoring the yaml values, since this is runtime-only by design.
#
# Self-managed; qa binary + a yaml derived from microservice.qa.yaml with
# BOTH auth.issuer (this service mints) AND auth.jwt (this service validates
# its OWN tokens) wired to the SAME issuer — the round-trip the framework's
# own unit tests prove in isolation, here proven over real HTTP against a
# real database. The RSA signing key is generated IN THIS SCRIPT via openssl
# (qa-only material, never committed, never reused across runs).
#
# Run from anywhere:  bash qa/auth_selfissued.sh
# Pick a dialect:      BACKEND=mysql bash qa/auth_selfissued.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"

SERVER_BIN="/tmp/omnicore-example-users-qa-authselfissued-${BACKEND:-postgres}"
SERVER_LOG="/tmp/omnicore-example-users-qa-authselfissued-${BACKEND:-postgres}.log"
WORK="/tmp/omnicore-qa-authselfissued-${BACKEND:-postgres}"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
stop_server() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port "${HTTP_PORT:-8081}"; kill_port "${GRPC_PORT:-9091}"
}
cleanup() { stop_server; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
mkdir -p "$WORK"

boot() { # boot <yaml>
  stop_server
  : > "$SERVER_LOG"
  ( cd "$REPO_ROOT" && APP_PROFILE=dev OMNICORE_CONFIG_PATH="$1" exec "$SERVER_BIN" >>"$SERVER_LOG" 2>&1 ) &
  SERVER_PID=$!
  local deadline=$(( $(date +%s) + 30 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    curl -skf -o /dev/null "$BASE/livez" && return 0
    sleep 0.5
  done
  bad "server not ready ($1)"; tail -n 40 "$SERVER_LOG"; exit 1
}

# --- RS256 hand-minting over a THROWAWAY key (edge-case tokens the real
# Issuer would never produce — expired/wrong-aud/unknown-kid/forged) ---
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
mint() { # mint <kid> <keyfile> <aud> <exp-epoch>
  local kid="$1" keyfile="$2" aud="$3" exp="$4" header payload sig
  header=$(printf '{"alg":"RS256","typ":"JWT","kid":"%s"}' "$kid" | b64url)
  payload=$(printf '{"sub":"forged-user","iss":"%s","aud":"%s","exp":%s}' "$ISS" "$aud" "$exp" | b64url)
  sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$keyfile" -binary | b64url)
  printf '%s.%s.%s' "$header" "$payload" "$sig"
}

# jf <json> <path...> — tiny JSON field extractor (avoids a jq dependency).
jf() { python3 -c '
import sys, json
d = json.load(sys.stdin)
for k in sys.argv[1:]:
    d = d[k]
print(d)
' "${@:2}" <<<"$1"; }

api() { # api <method> <path> <json-body>  -> sets RESP, STATUS
  local method="$1" path="$2" body="${3:-}"
  local tmp; tmp=$(mktemp)
  if [ -n "$body" ]; then
    STATUS=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" -H "Content-Type: application/json" -d "$body") || STATUS="000"
  else
    STATUS=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" "${@:4}") || STATUS="000"
  fi
  RESP=$(cat "$tmp"); rm -f "$tmp"
}
api_auth() { # api_auth <method> <path> <bearer>  -> sets RESP, STATUS
  local method="$1" path="$2" bearer="$3"
  local tmp; tmp=$(mktemp)
  STATUS=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$BASE$path" -H "Authorization: Bearer $bearer") || STATUS="000"
  RESP=$(cat "$tmp"); rm -f "$tmp"
}

ISS="http://qa-selfissued"
AUD="qa-selfissued-api"

# derive_yaml <out> <current-kid> <current-keyfile> [<previous-kid> <previous-keyfile>]
derive_yaml() {
  python3 - "$@" <<'PYEOF'
import sys
out, cur_kid, cur_key = sys.argv[1], sys.argv[2], sys.argv[3]
prev_kid, prev_key = (sys.argv[4], sys.argv[5]) if len(sys.argv) > 5 else (None, None)

def indented(path, pad=10):
    return "".join(" " * pad + l + "\n" for l in open(path).read().splitlines())

keys = (
    "      - kid: \"%s\"\n"
    "        algorithm: RS256\n"
    "        state: current\n"
    "        privateKeyPem: |\n%s"
) % (cur_kid, indented(cur_key))
if prev_kid:
    keys += (
        "      - kid: \"%s\"\n"
        "        algorithm: RS256\n"
        "        state: previous\n"
        "        privateKeyPem: |\n%s"
    ) % (prev_kid, indented(prev_key))

base = open("microservice.qa.yaml").read()
auth_block = (
"auth:\n"
"  mode: jwt\n"
"  publicRoutes: [\"GET /livez\", \"POST /qa/auth/login\", \"POST /qa/auth/refresh\", \"POST /qa/auth/logout\", \"POST /qa/auth/revoke-access\", \"GET /qa/auth/ttl\", \"POST /qa/auth/ttl\"]\n"
"  authorization:\n"
"    enabled: true\n"
"  jwt:\n"
"    algorithms: [RS256]\n"
"    issuer: \"http://qa-selfissued\"\n"
"    audience: \"qa-selfissued-api\"\n"
"    jwksUrl: \"${BASE_URL}/.well-known/jwks.json\"\n"
"  issuer:\n"
"    enabled: true\n"
"    selfUrl: \"http://qa-selfissued\"\n"
"    audience: [\"qa-selfissued-api\"]\n"
"    tokenTtlSeconds: 8\n"
"    maxTokenTtlSeconds: 3600\n"
"    refreshTokenTtlSeconds: 3600\n"
"    keys:\n" + keys +
"    jwks:\n"
"      path: /.well-known/jwks.json\n"
)
a = base.replace("auth:\n  mode: disabled\n", auth_block, 1)
assert a != base, "auth: mode: disabled anchor not found in microservice.qa.yaml"
cache_block = (
"cache:\n"
"  shared:\n"
"    store: redis\n"
"    redis:\n"
"      addr: \"${SHARED_REDIS_ADDR}\"\n"
"      keyPrefix: \"${SHARED_REDIS_KEY_PREFIX}qa-auth-selfissued-\"\n"
"      failMode: open\n"
"      timeoutMs: 200\n"
"\n"
)
open(out, "w").write(cache_block + a)
PYEOF
}

##############################################################################
sec "0. Build + key material + derived yamls"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port "${HTTP_PORT:-8081}"; kill_port "${GRPC_PORT:-9091}"
qa_db_exec "DROP TABLE IF EXISTS qa_refresh_tokens" >/dev/null 2>&1 || true
ok "build ready"

title "0.2 RSA signing keys (current + a second one for the rotation exercise)"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$WORK/key1.pem" >/dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$WORK/key2.pem" >/dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$WORK/throwaway.pem" >/dev/null 2>&1
[ -s "$WORK/key1.pem" ] && [ -s "$WORK/key2.pem" ] && ok "keys generated" || { bad "key generation failed"; exit 1; }

title "0.3 Derive base.yaml (single key: qa-key-1 current) + rotated.yaml (qa-key-2 current, qa-key-1 previous)"
derive_yaml "$WORK/base.yaml" "qa-key-1" "$WORK/key1.pem"
derive_yaml "$WORK/rotated.yaml" "qa-key-2" "$WORK/key2.pem" "qa-key-1" "$WORK/key1.pem"
export BASE_URL="$BASE" SHARED_REDIS_ADDR="${SHARED_REDIS_ADDR:-localhost:6380}" SHARED_REDIS_KEY_PREFIX="${SHARED_REDIS_KEY_PREFIX:-omnicore-example-users-shared-}"
# ${...} placeholders above are resolved by the framework's OWN yaml
# interpolation at boot (load.go), reading these exported env vars — the
# derived yaml ships the placeholders verbatim, exactly like a real
# microservice.<profile>.yaml would.
ok "yamls derived"

FUTURE=$(( $(date +%s) + 3600 ))
PAST=$(( $(date +%s) - 3600 ))

##############################################################################
sec "A. Happy path — self-issue, self-validate, permission gate"
##############################################################################
boot "$WORK/base.yaml"; ok "booted base.yaml"

title "A.1 login mints access+refresh"
api POST /qa/auth/login '{"subject":"qa-alice","permissions":["auth:read"]}'
if [ "$STATUS" = "200" ]; then
  ACCESS_A=$(jf "$RESP" data access_token)
  REFRESH_A=$(jf "$RESP" data refresh_token)
  JTI_A=$(jf "$RESP" data jti)
  [ -n "$ACCESS_A" ] && [ -n "$REFRESH_A" ] && ok "login returned access+refresh" || bad "A.1 missing token fields"
else
  bad "A.1 login (got $STATUS): $RESP"
fi

title "A.2 whoami validates the self-issued token through this service's OWN auth.jwt"
api_auth GET /qa/auth/whoami "$ACCESS_A"
[ "$STATUS" = "200" ] && [ "$(jf "$RESP" data subject)" = "qa-alice" ] && ok "self-validation round trip" || bad "A.2 (got $STATUS): $RESP"

title "A.3 permission GRANTED (login carried permissions:[auth:read])"
[ "$STATUS" = "200" ] && ok "permission granted" || bad "A.3 unexpected status $STATUS"

title "A.4 permission DENIED (login without any permissions claim)"
api POST /qa/auth/login '{"subject":"qa-bob"}'
NOPERM_ACCESS=$(jf "$RESP" data access_token)
api_auth GET /qa/auth/whoami "$NOPERM_ACCESS"
[ "$STATUS" = "403" ] && echo "$RESP" | grep -q 'MissingPermissionNotification' && ok "permission denied" || bad "A.4 (got $STATUS): $RESP"

##############################################################################
sec "B. Token edge cases — the VALIDATOR's rejections, independent of the Issuer"
##############################################################################

title "B.1 no token -> 401 MissingAuthorization"
api GET /qa/auth/whoami
[ "$STATUS" = "401" ] && echo "$RESP" | grep -q 'MissingAuthorizationNotification' && ok "no token rejected" || bad "B.1 (got $STATUS): $RESP"

title "B.2 forged/garbage token -> 401"
api_auth GET /qa/auth/whoami "forged.garbage.token"
[ "$STATUS" = "401" ] && ok "forged rejected" || bad "B.2 (got $STATUS): $RESP"

title "B.3 wrong aud (real key + real kid, bad aud) -> 401"
WRONGAUD=$(mint "qa-key-1" "$WORK/key1.pem" "someone-else" "$FUTURE")
api_auth GET /qa/auth/whoami "$WRONGAUD"
[ "$STATUS" = "401" ] && ok "wrong aud rejected" || bad "B.3 (got $STATUS): $RESP"

title "B.4 unknown kid (different, never-published key) -> 401"
UNKNOWNKID=$(mint "never-published-kid" "$WORK/throwaway.pem" "$AUD" "$FUTURE")
api_auth GET /qa/auth/whoami "$UNKNOWNKID"
[ "$STATUS" = "401" ] && ok "unknown kid rejected" || bad "B.4 (got $STATUS): $RESP"

title "B.5 real access token, wait past its 8s TTL -> 401 ExpiredToken"
api POST /qa/auth/login '{"subject":"qa-expiry","permissions":["auth:read"]}'
EXP_ACCESS=$(jf "$RESP" data access_token)
sleep 9
api_auth GET /qa/auth/whoami "$EXP_ACCESS"
[ "$STATUS" = "401" ] && echo "$RESP" | grep -q 'ExpiredTokenNotification' && ok "expired token rejected" || bad "B.5 (got $STATUS): $RESP"

##############################################################################
sec "C. Refresh — rotation, fresh claims, reuse detection revokes the family"
##############################################################################

title "C.1 login then refresh: token rotates, claims are RE-SUPPLIED fresh"
api POST /qa/auth/login '{"subject":"qa-carol","permissions":["auth:read"]}'
RT1=$(jf "$RESP" data refresh_token)
api POST /qa/auth/refresh "{\"refresh_token\":\"$RT1\",\"permissions\":[\"auth:read\",\"auth:admin\"]}"
if [ "$STATUS" = "200" ]; then
  RT2=$(jf "$RESP" data refresh_token)
  ACCESS_C=$(jf "$RESP" data access_token)
  [ "$RT2" != "$RT1" ] && ok "refresh token rotated (new value)" || bad "C.1 refresh token did not rotate"
  api_auth GET /qa/auth/whoami "$ACCESS_C"
  echo "$RESP" | grep -q 'auth:admin' && ok "redeemed access token carries the FRESH permissions" || bad "C.1 fresh claims not reflected: $RESP"
else
  bad "C.1 refresh (got $STATUS): $RESP"
fi

title "C.2 replaying the FIRST (already-redeemed) refresh token is reuse -> revokes the family"
api POST /qa/auth/refresh "{\"refresh_token\":\"$RT1\"}"
[ "$STATUS" = "401" ] && echo "$RESP" | grep -qi 'reuse detected' && ok "reuse detected on the old token" || bad "C.2 (got $STATUS): $RESP"

title "C.3 the NEWEST (rotated) refresh token is ALSO dead — the whole family was revoked"
api POST /qa/auth/refresh "{\"refresh_token\":\"$RT2\"}"
[ "$STATUS" = "401" ] && echo "$RESP" | grep -qi 'reuse detected\|revoked' && ok "family-wide revoke confirmed" || bad "C.3 (got $STATUS): $RESP"

##############################################################################
sec "D. Explicit revoke — /qa/auth/logout via RefreshTokenStore.RevokeFamily"
##############################################################################

title "D.1 login, logout, then refresh fails"
api POST /qa/auth/login '{"subject":"qa-dave"}'
RT_D=$(jf "$RESP" data refresh_token)
api POST /qa/auth/logout "{\"refresh_token\":\"$RT_D\"}"
[ "$STATUS" = "200" ] && [ "$(jf "$RESP" data revoked)" = "True" ] && ok "logout revoked" || bad "D.1 logout (got $STATUS): $RESP"

api POST /qa/auth/refresh "{\"refresh_token\":\"$RT_D\"}"
[ "$STATUS" = "401" ] && ok "refresh after logout rejected" || bad "D.1b (got $STATUS): $RESP"

##############################################################################
sec "E. Access-token revoke — /qa/auth/revoke-access via the TokenChecker denylist"
##############################################################################

title "E.1 a cryptographically-valid, unexpired access token stops working after revoke-access"
api POST /qa/auth/login '{"subject":"qa-erin","permissions":["auth:read"]}'
ACCESS_E=$(jf "$RESP" data access_token)
JTI_E=$(jf "$RESP" data jti)

api_auth GET /qa/auth/whoami "$ACCESS_E"
[ "$STATUS" = "200" ] && ok "access token valid before revoke" || bad "E.1 pre-revoke (got $STATUS): $RESP"

api POST /qa/auth/revoke-access "{\"jti\":\"$JTI_E\",\"ttl_seconds\":60}"
[ "$STATUS" = "200" ] && ok "revoke-access accepted" || bad "E.1 revoke call (got $STATUS): $RESP"

api_auth GET /qa/auth/whoami "$ACCESS_E"
[ "$STATUS" = "401" ] && ok "SAME still-unexpired token now rejected (in-process TokenChecker denylist)" || bad "E.1 post-revoke (got $STATUS): $RESP"

title "E.2 a DIFFERENT token (different jti) from the same subject is unaffected"
api POST /qa/auth/login '{"subject":"qa-erin","permissions":["auth:read"]}'
ACCESS_E2=$(jf "$RESP" data access_token)
api_auth GET /qa/auth/whoami "$ACCESS_E2"
[ "$STATUS" = "200" ] && ok "revoke-access is per-jti, not per-subject" || bad "E.2 (got $STATUS): $RESP"

##############################################################################
sec "F. JWKS document — every key present, zero private material"
##############################################################################

title "F.1 GET /.well-known/jwks.json"
JWKS=$(curl -sS "$BASE/.well-known/jwks.json")
echo "$JWKS" | grep -q '"qa-key-1"' && ok "kid qa-key-1 present" || bad "F.1 kid missing: $JWKS"

title "F.2 no private key fields ever leak"
LEAK=0
for field in '"d"' '"p"' '"q"' '"dp"' '"dq"' '"qi"'; do
  echo "$JWKS" | grep -q "$field" && LEAK=1
done
[ "$LEAK" = "0" ] && ok "no private material in JWKS" || bad "F.2 private field leaked: $JWKS"

##############################################################################
sec "G. Key rotation — a previous-key token still validates; new logins use the new key"
##############################################################################

title "G.1 mint a token signed by qa-key-1 (about to be demoted) — real key, long expiry"
# Hand-minted with a long expiry (not a real /login, whose 8s TTL would race
# the reboot below) — same real key1.pem the CURRENT key is signing with
# right now, so this proves exactly what G.3 needs: a token this service
# itself could have issued a moment ago still validates once that key is
# demoted to previous.
PRE_ROTATION_ACCESS=$(mint "qa-key-1" "$WORK/key1.pem" "$AUD" "$FUTURE")
api_auth GET /qa/auth/whoami "$PRE_ROTATION_ACCESS"
[ "$STATUS" = "403" ] && echo "$RESP" | grep -q 'MissingPermissionNotification' && ok "pre-rotation token valid (reached the permission gate, not rejected as invalid)" || bad "G.1 (got $STATUS): $RESP"

title "G.2 reboot with qa-key-2 CURRENT, qa-key-1 PREVIOUS"
boot "$WORK/rotated.yaml"; ok "booted rotated.yaml"

title "G.3 the PRE-rotation token (signed by the now-previous key) STILL validates"
# Same 403-not-401 signal as G.1: a signature/kid failure would be 401
# InvalidToken. Reaching the permission gate (403) proves the now-PREVIOUS
# key still verified the signature after rotation.
api_auth GET /qa/auth/whoami "$PRE_ROTATION_ACCESS"
[ "$STATUS" = "403" ] && echo "$RESP" | grep -q 'MissingPermissionNotification' && ok "previous-key token still valid after rotation" || bad "G.3 (got $STATUS): $RESP"

title "G.4 a FRESH login after rotation signs with the NEW current key (qa-key-2)"
api POST /qa/auth/login '{"subject":"qa-post-rotation","permissions":["auth:read"]}'
POST_ROTATION_ACCESS=$(jf "$RESP" data access_token)
HEADER=$(printf '%s' "$POST_ROTATION_ACCESS" | cut -d. -f1)
# base64url decode the header (Python handles missing padding).
KID=$(python3 -c "import base64,json,sys; h=sys.argv[1]; h+='='*(-len(h)%4); print(json.loads(base64.urlsafe_b64decode(h))['kid'])" "$HEADER")
[ "$KID" = "qa-key-2" ] && ok "fresh login signs with the new current key" || bad "G.4 unexpected kid: $KID"

title "G.5 JWKS after rotation carries BOTH keys (current + previous)"
JWKS2=$(curl -sS "$BASE/.well-known/jwks.json")
echo "$JWKS2" | grep -q '"qa-key-1"' && echo "$JWKS2" | grep -q '"qa-key-2"' && ok "both kids published" || bad "G.5 (missing a kid): $JWKS2"

##############################################################################
sec "H. Runtime TTL retuning — Issuer.Set/Get{Token,MaxToken,RefreshToken}TTL"
##############################################################################
# The derived yaml declares tokenTtlSeconds: 8, maxTokenTtlSeconds: 3600,
# refreshTokenTtlSeconds: 3600 — the baseline every assertion below reads
# against. Each setter is proven by what the NEXT token actually carries, not
# by the getter echoing back what was just written.

# ttl_now <field> -> the live value, straight from the Issuer's getters
ttl_now() { api GET /qa/auth/ttl; jf "$RESP" data "$1"; }

# secs_until <rfc3339> -> whole seconds from now until that instant. Go emits
# RFC3339 with up to 9 fractional digits; fromisoformat tops out at 6, so the
# tail is trimmed before parsing.
secs_until() { python3 -c '
import sys, re, datetime
t = re.sub(r"(\.\d{6})\d+", r"\1", sys.argv[1].replace("Z", "+00:00"))
d = datetime.datetime.fromisoformat(t)
print(int((d - datetime.datetime.now(datetime.timezone.utc)).total_seconds()))
' "$1"; }

# near <actual> <expected> <tolerance>
near() { local a="$1" e="$2" t="$3"; [ "$a" -ge $((e-t)) ] && [ "$a" -le $((e+t)) ]; }

# ttl_reject <json-body> <expected-substring> — asserts 400 AND that the three
# live values are byte-identical afterwards (a rejected setter changes nothing).
ttl_reject() {
  local body="$1" want="$2" before after
  before=$(api GET /qa/auth/ttl; printf '%s' "$RESP")
  api POST /qa/auth/ttl "$body"
  local status="$STATUS" resp="$RESP"
  after=$(api GET /qa/auth/ttl; printf '%s' "$RESP")
  if [ "$status" = "400" ] && grep -qi -- "$want" <<<"$resp" && [ "$before" = "$after" ]; then
    ok "rejected $body ($want) with state untouched"
  else
    bad "H.2 $body -> status=$status resp=$resp | before=$before after=$after"
  fi
}

title "H.1 the getters reflect the yaml the service booted with"
api GET /qa/auth/ttl
if [ "$STATUS" = "200" ] &&
   [ "$(jf "$RESP" data token_ttl_seconds)" = "8" ] &&
   [ "$(jf "$RESP" data max_token_ttl_seconds)" = "3600" ] &&
   [ "$(jf "$RESP" data refresh_token_ttl_seconds)" = "3600" ]; then
  ok "8 / 3600 / 3600 as declared"
else
  bad "H.1 (got $STATUS): $RESP"
fi

title "H.2 every rejection the setters owe — and none of them mutates state"
# The expected substrings deliberately stop before the "> 0" — Go's JSON
# encoder escapes '>' as >, so matching the operator would assert on the
# encoding rather than on the message.
ttl_reject '{"token_ttl_seconds":0}'              'SetTokenTTL: must be'
ttl_reject '{"token_ttl_seconds":-5}'             'SetTokenTTL: must be'
ttl_reject '{"token_ttl_seconds":7200}'           'exceeds the current MaxTokenTTL'
ttl_reject '{"max_token_ttl_seconds":0}'          'cannot be removed at runtime'
ttl_reject '{"max_token_ttl_seconds":-1}'         'cannot be removed at runtime'
ttl_reject '{"max_token_ttl_seconds":4}'          'below the current TokenTTL'
ttl_reject '{"refresh_token_ttl_seconds":0}'      'SetRefreshTokenTTL: must be'

title "H.3 SetTokenTTL — the next access token carries the NEW default"
api POST /qa/auth/ttl '{"token_ttl_seconds":90}'
[ "$STATUS" = "200" ] && [ "$(ttl_now token_ttl_seconds)" = "90" ] && ok "default now 90s" || bad "H.3 set (got $STATUS): $RESP"
api POST /qa/auth/login '{"subject":"qa-ttl-default"}'
LIFE=$(secs_until "$(jf "$RESP" data expires_at)")
near "$LIFE" 90 5 && ok "minted token lives ~90s, not the yaml's 8s (got ${LIFE}s)" || bad "H.3 token life ${LIFE}s"

title "H.4 SetMaxTokenTTL — the new ceiling caps a per-request TokenRequest.TTL"
api POST /qa/auth/ttl '{"max_token_ttl_seconds":120}'
[ "$STATUS" = "200" ] && [ "$(ttl_now max_token_ttl_seconds)" = "120" ] && ok "ceiling now 120s" || bad "H.4 set (got $STATUS): $RESP"
api POST /qa/auth/login '{"subject":"qa-ttl-cap","ttl_seconds":3000}'
LIFE=$(secs_until "$(jf "$RESP" data expires_at)")
near "$LIFE" 120 5 && ok "a 3000s request was capped to the live 120s ceiling (got ${LIFE}s)" || bad "H.4 capped life ${LIFE}s"

title "H.5 SetRefreshTokenTTL — the next refresh token carries the NEW lifetime"
api POST /qa/auth/ttl '{"refresh_token_ttl_seconds":7200}'
[ "$STATUS" = "200" ] && [ "$(ttl_now refresh_token_ttl_seconds)" = "7200" ] && ok "refresh lifetime now 7200s" || bad "H.5 set (got $STATUS): $RESP"
api POST /qa/auth/login '{"subject":"qa-ttl-refresh"}'
RLIFE=$(secs_until "$(jf "$RESP" data refresh_expires_at)")
near "$RLIFE" 7200 30 && ok "refresh token lives ~7200s, not the yaml's 3600s (got ${RLIFE}s)" || bad "H.5 refresh life ${RLIFE}s"

title "H.6 the pair moves together in ONE call (ceiling raised before the default)"
api POST /qa/auth/ttl '{"token_ttl_seconds":300,"max_token_ttl_seconds":600}'
if [ "$STATUS" = "200" ] && [ "$(ttl_now token_ttl_seconds)" = "300" ] && [ "$(ttl_now max_token_ttl_seconds)" = "600" ]; then
  ok "300/600 applied in one request"
else
  bad "H.6 (got $STATUS): $RESP"
fi

title "H.7 a reboot restores the yaml — runtime changes are deliberately not persisted"
boot "$WORK/rotated.yaml"
api GET /qa/auth/ttl
if [ "$(jf "$RESP" data token_ttl_seconds)" = "8" ] &&
   [ "$(jf "$RESP" data max_token_ttl_seconds)" = "3600" ] &&
   [ "$(jf "$RESP" data refresh_token_ttl_seconds)" = "3600" ]; then
  ok "back to 8 / 3600 / 3600 — the drift the setters log a Warn about"
else
  bad "H.7 (got $STATUS): $RESP"
fi

##############################################################################
hr
printf 'RESULT: \033[1;32mPASS=%d\033[0m \033[1;31mFAIL=%d\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
