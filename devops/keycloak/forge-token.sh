#!/usr/bin/env bash
# Forges a JWT signed with the test realm's own RSA signing key, so the token
# passes SIGNATURE validation (its kid matches the realm JWKS) but carries a
# deliberately broken claim/header the middleware must reject on its own merit:
#
#   expired   — exp one hour in the past (everything else valid) → the local
#               validator must surface ExpiredTokenNotification, DISTINCT from
#               the InvalidTokenNotification a malformed/wrong-signature token
#               produces. This is the only way to exercise the expired branch:
#               Keycloak never mints a token already past its exp, and waiting
#               out a real token's 5-minute lifetime is impractical in a suite.
#   wrongalg  — re-signed HS256 (symmetric) using the base64 public cert bytes
#               as the shared secret. The header advertises alg=HS256, which is
#               NOT in auth.algorithms ([RS256]); the validator must reject it
#               on the algorithm allowlist BEFORE any signature check (the
#               classic RS256→HS256 confusion-attack guard).
#
# The realm private key is read from realm-export.json (the same key Keycloak
# imports at boot and publishes on its JWKS endpoint), and a live alice token
# is minted first purely to copy its header kid + claim shape (aud/iss/sub) so
# the forged token is indistinguishable from a real one except for the single
# axis under test.
#
# Usage:
#   ./forge-token.sh expired          # RS256, real kid, exp in the past
#   ./forge-token.sh valid            # RS256, real kid, exp in the future (chain sanity)
#   ./forge-token.sh wrongalg         # HS256 header (algorithm-allowlist reject)
#
# Requires python3 + the `cryptography` package (already a QA dependency).
set -eu

MODE="${1:-expired}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REALM_EXPORT="${REALM_EXPORT:-$SCRIPTS_DIR/realm-export.json}"

# A live token donates its kid + claim shape. Fail loudly if Keycloak is down —
# a forged token with a stale/guessed kid would fail signature validation and
# mask the very branch we mean to test.
REAL_TOKEN=$("$SCRIPTS_DIR/mint-token.sh" alice)

MODE="$MODE" REALM_EXPORT="$REALM_EXPORT" REAL_TOKEN="$REAL_TOKEN" python3 - <<'PY'
import json, base64, time, os, sys
from cryptography.hazmat.primitives.serialization import load_der_private_key
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives import hashes, hmac

def b64u(b): return base64.urlsafe_b64encode(b).decode().rstrip('=')
def dec(seg): return json.loads(base64.urlsafe_b64decode(seg + '=' * (-len(seg) % 4)))

mode = os.environ["MODE"]
h, p, _ = os.environ["REAL_TOKEN"].split('.')
hdr, claims = dec(h), dec(p)

comps = json.load(open(os.environ["REALM_EXPORT"]))["components"]["org.keycloak.keys.KeyProvider"]
rsa = [c for c in comps if "privateKey" in c.get("config", {})][0]["config"]
priv = load_der_private_key(base64.b64decode(rsa["privateKey"][0]), password=None)

now = int(time.time())
claims = dict(claims)
claims["iat"] = now - 5
claims["nbf"] = now - 5

if mode == "expired":
    claims["exp"] = now - 3600
    header = {"alg": "RS256", "typ": "JWT", "kid": hdr["kid"]}
elif mode == "valid":
    claims["exp"] = now + 3600
    header = {"alg": "RS256", "typ": "JWT", "kid": hdr["kid"]}
elif mode == "wrongalg":
    claims["exp"] = now + 3600
    header = {"alg": "HS256", "typ": "JWT", "kid": hdr["kid"]}
else:
    sys.stderr.write("unknown mode: %s\n" % mode); sys.exit(2)

signing_input = (b64u(json.dumps(header).encode()) + '.' + b64u(json.dumps(claims).encode())).encode()

if header["alg"] == "RS256":
    sig = priv.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
else:  # HS256 confusion attempt — secret is the realm cert bytes (public info)
    secret = base64.b64decode(rsa["certificate"][0])
    hm = hmac.HMAC(secret, hashes.SHA256()); hm.update(signing_input); sig = hm.finalize()

print(signing_input.decode() + '.' + b64u(sig))
PY
