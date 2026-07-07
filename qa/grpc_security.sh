#!/usr/bin/env bash
# gRPC security suite — every auth posture of the gRPC plane, end to end,
# with REAL tokens (RS256 minted here via openssl) and REAL certificates:
#
#   A. inherit + jwt + authorization: missing/forged/expired tokens reject
#      at the main door; permission gates deny/grant by the `permissions`
#      claim (users:read / users:write).
#   B. internal posture (same IdP material): anonymous passes the gates;
#      the SAME expired token that door A rejected passes with attribution;
#      a forwarded user without the permission is still denied; forged
#      rejects; anonymous reads are dev-trusted (Phone read_mask allowed).
#   C. mtls posture (internal CA + server/client certs): a certless client
#      cannot even connect; a certified client passes anonymously and its
#      SYNTHETIC IDENTITY (SAN service-a) observably flows into ToCriteria —
#      the users:admin Phone restriction fires for the service identity,
#      while door B's anonymous (nil identity) read was allowed.
#
# Self-managed; qa binary + variant yamls derived from microservice.qa.yaml.
# Run from anywhere:  bash qa/grpc_security.sh
set -u

BASE="${BASE:-http://localhost:8080}"
GRPC_BASE="${GRPC_BASE:-http://localhost:9090}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/qa/_backend.sh"
SERVER_BIN="/tmp/omnicore-example-users-qa-grpcsec"
SERVER_LOG="/tmp/omnicore-example-users-qa-grpcsec.log"
WORK="/tmp/omnicore-qa-grpcsec"

PASS=0; FAIL=0; SERVER_PID=""
hr()    { printf '\n\033[1;36m%s\033[0m\n' "============================================================"; }
sec()   { hr; printf '\033[1;33m== %s ==\033[0m\n' "$1"; }
title() { printf '\n\033[1;37m--- %s ---\033[0m\n' "$1"; }
ok()    { printf '\033[1;32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()   { printf '\033[1;31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
kill_port() { local p; p=$(lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); [ -n "$p" ] && { kill -9 $p 2>/dev/null || true; sleep 1; }; }
stop_server() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  kill_port 8080; kill_port 9090
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
    curl -skf -o /dev/null "$BASE/health" && return 0
    sleep 0.5
  done
  bad "server not ready ($1)"; tail -n 30 "$SERVER_LOG"; exit 1
}

# --- RS256 JWT minting over the suite's own keypair ---
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
mint() { # mint <exp-epoch> <permissions-json-array>
  local header payload sig
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"sub":"qa-user","iss":"qa-sec","aud":"qa-sec","exp":%s,"permissions":%s}' "$1" "$2" | b64url)
  sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$WORK/jwt.key" -binary | b64url)
  printf '%s.%s.%s' "$header" "$payload" "$sig"
}

grpc_call() { # grpc_call <base> <procedure> <json> [curl-extra...]
  local base="$1" procedure="$2" body="$3"; shift 3
  local tmp; tmp=$(mktemp)
  RPC_STATUS=$(curl -skS -o "$tmp" -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    "$base/users.v1.UsersService/$procedure" -d "$body" "$@") || RPC_STATUS="000"
  RPC_BODY=$(cat "$tmp"); rm -f "$tmp"
}

##############################################################################
sec "0. Build + key material"
##############################################################################
title "0.1 Build with -tags '$QA_BUILD_TAGS qa'"
(cd "$REPO_ROOT" && go build -tags "$QA_BUILD_TAGS qa" -o "$SERVER_BIN" ./bootstrap) || { bad "build failed"; exit 1; }
kill_port 8080; kill_port 9090
qa_db_reset_domain; qa_mongo_reset; sleep 2

title "0.2 JWT keypair + variant yamls"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$WORK/jwt.key" >/dev/null 2>&1
openssl pkey -in "$WORK/jwt.key" -pubout -out "$WORK/jwt.pub" >/dev/null 2>&1
python3 - "$REPO_ROOT/microservice.qa.yaml" "$WORK" <<'PYEOF2'
import sys
src, work = sys.argv[1], sys.argv[2]
base = open(src).read()
pem = "".join("      " + l + "\n" for l in open(work + "/jwt.pub").read().splitlines())
jwt_block = ("auth:\n  mode: jwt\n  publicRoutes: [\"GET /health\"]\n"
             "  authorization:\n    enabled: true\n"
             "  jwt:\n    issuer: \"qa-sec\"\n    audience: \"qa-sec\"\n    publicKeyPem: |\n" + pem)
a = base.replace("auth:\n  mode: disabled", jwt_block, 1)
open(work + "/inherit.yaml", "w").write(a)
b = a.replace("grpc:\n", "grpc:\n  auth:\n    mode: internal\n", 1)
open(work + "/internal.yaml", "w").write(b)
c = a.replace("grpc:\n", ("grpc:\n  auth:\n    mode: mtls\n"
    "  certFile: \"%s/server.crt\"\n  keyFile: \"%s/server.key\"\n  clientCAFile: \"%s/ca.crt\"\n") % (work, work, work), 1)
open(work + "/mtls.yaml", "w").write(c)
PYEOF2
ok "yamls derived (inherit / internal / mtls)"

title "0.3 mTLS certificate chain (CA + server localhost + client service-a)"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$WORK/ca.key" >/dev/null 2>&1
openssl req -x509 -new -key "$WORK/ca.key" -days 1 -subj "/CN=omnicore-qa-ca" -out "$WORK/ca.crt" >/dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$WORK/server.key" >/dev/null 2>&1
openssl req -new -key "$WORK/server.key" -subj "/CN=localhost" -out "$WORK/server.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > "$WORK/server.ext"
openssl x509 -req -in "$WORK/server.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial -days 1 -extfile "$WORK/server.ext" -out "$WORK/server.crt" >/dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$WORK/client.key" >/dev/null 2>&1
openssl req -new -key "$WORK/client.key" -subj "/CN=service-a" -out "$WORK/client.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:service-a\nextendedKeyUsage=clientAuth\n' > "$WORK/client.ext"
openssl x509 -req -in "$WORK/client.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial -days 1 -extfile "$WORK/client.ext" -out "$WORK/client.crt" >/dev/null 2>&1
[ -s "$WORK/server.crt" ] && [ -s "$WORK/client.crt" ] && ok "chain ready" || { bad "cert chain failed"; exit 1; }

NOW=$(date +%s); FUTURE=$((NOW + 3600)); PAST=$((NOW - 3600))

##############################################################################
sec "A. Main door — inherit + jwt + authorization"
##############################################################################
boot "$WORK/inherit.yaml"; ok "booted inherit"

title "A.1 no token → unauthenticated"
grpc_call "$GRPC_BASE" ListUsers '{}'
[ "$RPC_STATUS" = "401" ] && echo "$RPC_BODY" | grep -q 'MissingAuthorizationNotification' && ok "missing token rejected" || { bad "A.1 (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 200; }

title "A.2 forged token → unauthenticated"
grpc_call "$GRPC_BASE" ListUsers '{}' -H "Authorization: Bearer forged.garbage.token"
[ "$RPC_STATUS" = "401" ] && ok "forged rejected" || bad "A.2 (got $RPC_STATUS)"

title "A.3 EXPIRED authentic token → unauthenticated (edge is strict)"
EXPIRED=$(mint "$PAST" '["users:read","users:write"]')
grpc_call "$GRPC_BASE" ListUsers '{}' -H "Authorization: Bearer $EXPIRED"
[ "$RPC_STATUS" = "401" ] && echo "$RPC_BODY" | grep -q 'ExpiredTokenNotification' && ok "expired rejected at the main door" || { bad "A.3 (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 200; }

title "A.4 valid token WITHOUT users:read → permission_denied"
NOREAD=$(mint "$FUTURE" '["something:else"]')
grpc_call "$GRPC_BASE" ListUsers '{}' -H "Authorization: Bearer $NOREAD"
[ "$RPC_STATUS" = "403" ] && echo "$RPC_BODY" | grep -q 'MissingPermissionNotification' && ok "gate denies" || { bad "A.4 (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 200; }

title "A.5 valid token WITH users:read → 200"
READER=$(mint "$FUTURE" '["users:read"]')
grpc_call "$GRPC_BASE" ListUsers '{"page":{"onlyTotal":true}}' -H "Authorization: Bearer $READER"
[ "$RPC_STATUS" = "200" ] && ok "gate grants read" || { bad "A.5 (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 200; }

title "A.6 valid token WITH users:write → create 200"
WRITER=$(mint "$FUTURE" '["users:write"]')
grpc_call "$GRPC_BASE" CreateUser '{"name":"Sec Alice","email":"sec.alice@example.com","document":"99093000001","userName":"grpcsec_alice"}' -H "Authorization: Bearer $WRITER"
[ "$RPC_STATUS" = "200" ] && ok "gate grants write" || { bad "A.6 (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; }

##############################################################################
sec "B. Internal plane — same IdP material, trusted posture"
##############################################################################
boot "$WORK/internal.yaml"; ok "booted internal"

title "B.1 anonymous create → 200 (gates pass on the trusted plane)"
grpc_call "$GRPC_BASE" CreateUser '{"name":"Sec Bob","email":"sec.bob@example.com","document":"99093000002","userName":"grpcsec_bob"}'
[ "$RPC_STATUS" = "200" ] && ok "anonymous internal write" || { bad "B.1 (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; }

title "B.2 the SAME expired token door A rejected → passes with attribution"
grpc_call "$GRPC_BASE" ListUsers '{"page":{"onlyTotal":true}}' -H "Authorization: Bearer $EXPIRED"
[ "$RPC_STATUS" = "200" ] && ok "expired-authentic attributed and served" || { bad "B.2 (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 200; }

title "B.3 forwarded user WITHOUT users:read → still denied (user is evaluated)"
grpc_call "$GRPC_BASE" ListUsers '{}' -H "Authorization: Bearer $NOREAD"
[ "$RPC_STATUS" = "403" ] && echo "$RPC_BODY" | grep -q 'MissingPermissionNotification' && ok "forwarded user gated" || { bad "B.3 (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 200; }

title "B.4 forged token → unauthenticated (lying attribution rejected)"
grpc_call "$GRPC_BASE" ListUsers '{}' -H "Authorization: Bearer forged.garbage.token"
[ "$RPC_STATUS" = "401" ] && ok "forged rejected on internal plane" || bad "B.4 (got $RPC_STATUS)"

title "B.5 anonymous read_mask Phone → allowed (nil identity = trusted)"
grpc_call "$GRPC_BASE" ListUsers '{"readMask":"phone","page":{"onlyTotal":true}}'
[ "$RPC_STATUS" = "200" ] && ok "anonymous trusted read" || { bad "B.5 (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 200; }

##############################################################################
sec "C. mTLS — the certificate IS the caller"
##############################################################################
GRPC_TLS="https://localhost:9090"
boot "$WORK/mtls.yaml"; ok "booted mtls"

title "C.1 certless client cannot even connect"
grpc_call "$GRPC_TLS" ListUsers '{}' --cacert "$WORK/ca.crt"
if [ "$RPC_STATUS" = "000" ]; then ok "TLS handshake refused without client cert"; else bad "C.1 (got $RPC_STATUS)"; fi

title "C.2 certified client (service-a) passes anonymously"
grpc_call "$GRPC_TLS" ListUsers '{"page":{"onlyTotal":true}}' --cacert "$WORK/ca.crt" --cert "$WORK/client.crt" --key "$WORK/client.key"
[ "$RPC_STATUS" = "200" ] && ok "mtls anonymous call served" || { bad "C.2 (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 200; }

title "C.3 the synthetic service identity observably flows: Phone restricted"
# FindUserByParamsQuery.ToCriteria restricts Phone unless users:admin — the
# certificate identity (service-a, no permissions) triggers it, while door
# B's anonymous nil-identity read (B.5) was allowed. Identity end to end.
grpc_call "$GRPC_TLS" ListUsers '{"readMask":"phone","page":{"onlyTotal":true}}' --cacert "$WORK/ca.crt" --cert "$WORK/client.crt" --key "$WORK/client.key"
if [ "$RPC_STATUS" = "403" ] && ! echo "$RPC_BODY" | grep -q 'MissingPermissionNotification'; then
  ok "cert identity reached ToCriteria (Phone restricted for service-a, NOT the gate)"
else
  bad "C.3 (got $RPC_STATUS)"; echo "$RPC_BODY" | head -c 300; echo
fi

##############################################################################
hr
printf 'RESULT: \033[1;32mPASS=%d\033[0m \033[1;31mFAIL=%d\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
