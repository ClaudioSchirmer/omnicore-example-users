//go:build qa

package qafixtures

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	fwcache "github.com/ClaudioSchirmer/omnicore/infra/cache"
	fwdb "github.com/ClaudioSchirmer/omnicore/infra/db/core"
	"github.com/ClaudioSchirmer/omnicore/web/authcore"
)

// ─── Self-provisioning (no migration files) ─────────────────────────────────

// ProvisionRefreshTokenTable creates qa_refresh_tokens if it does not exist,
// via the shared qaExecDDL translator (postgres + mysql hand-written, sqlserver
// + oracle derived mechanically — see provision_tsql.go / provision_oracle.go).
// Idempotent; called from the QA AuthFeature's constructor so the table exists
// before Mount, mirroring ProvisionGadgetTables. This schema is QA-only
// scaffolding for the RefreshTokenStore round-trip — never copy this table
// into a real IdP's schema, which would additionally want indexes tuned for
// its actual traffic and a garbage-collection job for expired rows.
func ProvisionRefreshTokenTable(ctx context.Context, eng fwdb.RelationalEngine) error {
	postgres := eng.Dialect().Placeholder(1) == "$1"

	var ddl string
	if postgres {
		ddl = `CREATE TABLE IF NOT EXISTS qa_refresh_tokens (
			hash        VARCHAR(64)  NOT NULL,
			family_id   VARCHAR(36)  NOT NULL,
			subject     VARCHAR(255) NOT NULL,
			audience    VARCHAR(512) NOT NULL,
			expires_at  TIMESTAMP    NOT NULL,
			used        BOOLEAN      NOT NULL DEFAULT false,
			revoked     BOOLEAN      NOT NULL DEFAULT false,
			created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
			PRIMARY KEY (hash)
		)`
	} else {
		ddl = `CREATE TABLE IF NOT EXISTS qa_refresh_tokens (
			hash        VARCHAR(64)  NOT NULL,
			family_id   VARCHAR(36)  NOT NULL,
			subject     VARCHAR(255) NOT NULL,
			audience    VARCHAR(512) NOT NULL,
			expires_at  DATETIME     NOT NULL,
			used        TINYINT(1)   NOT NULL DEFAULT 0,
			revoked     TINYINT(1)   NOT NULL DEFAULT 0,
			created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (hash)
		)`
	}
	return qaExecDDL(ctx, eng, ddl)
}

// ─── RefreshTokenStore — the QA implementation of authcore.RefreshTokenStore ─

// RefreshTokenStore persists refresh-token rotation state in qa_refresh_tokens.
// The Issuer owns the rotation/reuse-detection algorithm (see
// web/authcore.Issuer.RedeemRefreshToken); this adapter only stores/retrieves
// the hash the Issuer hands it — the raw refresh-token value never reaches
// this layer.
type RefreshTokenStore struct {
	eng fwdb.RelationalEngine
}

// NewRefreshTokenStore constructs the store. Call ProvisionRefreshTokenTable
// first (the AuthFeature constructor does this, mirroring GadgetFeature).
func NewRefreshTokenStore(eng fwdb.RelationalEngine) *RefreshTokenStore {
	return &RefreshTokenStore{eng: eng}
}

var _ authcore.RefreshTokenStore = (*RefreshTokenStore)(nil)

func (s *RefreshTokenStore) Save(ctx context.Context, rec authcore.RefreshTokenRecord) error {
	d := s.eng.Dialect()
	sql := fmt.Sprintf(
		"INSERT INTO qa_refresh_tokens (hash, family_id, subject, audience, expires_at, used, revoked) "+
			"VALUES (%s, %s, %s, %s, %s, %s, %s)",
		d.Placeholder(1), d.Placeholder(2), d.Placeholder(3), d.Placeholder(4),
		d.Placeholder(5), d.Placeholder(6), d.Placeholder(7),
	)
	// .UTC() explicitly: a bare TIMESTAMP/DATETIME column carries no zone, so
	// write and read must agree on ONE zone or comparisons against time.Now()
	// silently drift by the host's UTC offset (caught in manual smoke testing
	// — a 3600s-TTL token read back as already-expired).
	return s.eng.Querier().Exec(ctx, sql,
		rec.Hash, rec.FamilyID, rec.Subject, strings.Join(rec.Audience, ","),
		rec.ExpiresAt.UTC(), false, false,
	)
}

func (s *RefreshTokenStore) Lookup(ctx context.Context, hash string) (authcore.RefreshTokenRecord, error) {
	d := s.eng.Dialect()
	sql := fmt.Sprintf(
		"SELECT hash, family_id, subject, audience, expires_at, used, revoked "+
			"FROM qa_refresh_tokens WHERE hash = %s",
		d.Placeholder(1),
	)
	rows, err := s.eng.Querier().Query(ctx, sql, hash)
	if err != nil {
		return authcore.RefreshTokenRecord{}, fmt.Errorf("qafixtures: lookup refresh token: %w", err)
	}
	defer rows.Close()

	if !rows.Next() {
		return authcore.RefreshTokenRecord{}, authcore.ErrRefreshTokenNotFound
	}
	var hashCol, famCol, subCol, audCol, expCol, usedCol, revCol any
	if err := rows.Scan(&hashCol, &famCol, &subCol, &audCol, &expCol, &usedCol, &revCol); err != nil {
		return authcore.RefreshTokenRecord{}, fmt.Errorf("qafixtures: scan refresh token: %w", err)
	}
	if err := rows.Err(); err != nil {
		return authcore.RefreshTokenRecord{}, err
	}

	aud := toStr(audCol)
	var audience []string
	if aud != "" {
		audience = strings.Split(aud, ",")
	}
	return authcore.RefreshTokenRecord{
		Hash:      toStr(hashCol),
		FamilyID:  toStr(famCol),
		Subject:   toStr(subCol),
		Audience:  audience,
		ExpiresAt: toTime(expCol),
		Used:      toBool(usedCol),
		Revoked:   toBool(revCol),
	}, nil
}

func (s *RefreshTokenStore) MarkUsed(ctx context.Context, hash string) error {
	d := s.eng.Dialect()
	sql := fmt.Sprintf("UPDATE qa_refresh_tokens SET used = %s WHERE hash = %s", d.Placeholder(1), d.Placeholder(2))
	return s.eng.Querier().Exec(ctx, sql, true, hash)
}

func (s *RefreshTokenStore) RevokeFamily(ctx context.Context, familyID string) error {
	d := s.eng.Dialect()
	sql := fmt.Sprintf("UPDATE qa_refresh_tokens SET revoked = %s WHERE family_id = %s", d.Placeholder(1), d.Placeholder(2))
	return s.eng.Querier().Exec(ctx, sql, true, familyID)
}

// ─── Dialect-portable scan helpers ───────────────────────────────────────────
// Scan into `any` because the four drivers do not agree on the Go type a
// BOOLEAN/TINYINT(1)/BIT/NUMBER(1) or a DATETIME/TIMESTAMP column scans into —
// scanning into a fixed concrete type (bool, time.Time) would work on some
// engines and fail to scan on others. These helpers normalize defensively
// instead of assuming one driver's representation.

func toBool(v any) bool {
	switch t := v.(type) {
	case bool:
		return t
	case int64:
		return t != 0
	case int32:
		return t != 0
	case float64:
		return t != 0
	case []byte:
		return len(t) > 0 && (t[0] == '1' || t[0] == 't' || t[0] == 'T')
	case string:
		return t == "1" || strings.EqualFold(t, "true")
	default:
		return false
	}
}

var timeLayouts = []string{
	time.RFC3339Nano,
	"2006-01-02 15:04:05.999999999 -0700 MST",
	"2006-01-02 15:04:05.999999999",
	"2006-01-02T15:04:05.999999999",
	"2006-01-02 15:04:05",
}

func toTime(v any) time.Time {
	switch t := v.(type) {
	case time.Time:
		return t.UTC()
	case []byte:
		return parseTimeAny(string(t))
	case string:
		return parseTimeAny(t)
	default:
		return time.Time{}
	}
}

func parseTimeAny(s string) time.Time {
	for _, layout := range timeLayouts {
		if parsed, err := time.Parse(layout, s); err == nil {
			return parsed
		}
	}
	return time.Time{}
}

func toStr(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case []byte:
		return string(t)
	case nil:
		return ""
	default:
		return fmt.Sprint(t)
	}
}

// ─── RevocationChecker — the QA implementation of authcore.TokenChecker ─────

// RevocationChecker is an in-process access-token denylist keyed by `jti`,
// backed by Deps.SharedCache (Redis in the QA yaml) — the same seam a real
// deployment would use, per the design note in docs/content/sections/
// token-issuance.html#in-process-revocation: a jti denylist, TTL'd to the
// token's remaining lifetime, is the natural Wiring.TokenChecker payload.
type RevocationChecker struct {
	cache fwcache.Cache
}

func NewRevocationChecker(c fwcache.Cache) *RevocationChecker {
	return &RevocationChecker{cache: c}
}

var _ authcore.TokenChecker = (*RevocationChecker)(nil)

const revokedJTIPrefix = "qa-auth-revoked-jti:"

// Revoke marks jti as revoked for ttl (the token's remaining lifetime — past
// that point it would be rejected on expiry anyway, so the denylist entry can
// safely disappear). Called by the /qa/auth/revoke-access handler.
func (r *RevocationChecker) Revoke(ctx context.Context, jti string, ttl time.Duration) error {
	if r.cache == nil {
		return fmt.Errorf("qafixtures: RevocationChecker has no cache wired (cache.shared: missing from yaml)")
	}
	if ttl <= 0 {
		ttl = time.Second
	}
	return r.cache.Set(ctx, revokedJTIPrefix+jti, []byte("1"), ttl)
}

// Validate implements authcore.TokenChecker: called by the Validator AFTER
// local JWT verification passes. It extracts `jti` from the ALREADY-VERIFIED
// token without re-parsing signature/claims (that work is done; this only
// reads the payload segment) and rejects if that jti is on the denylist.
func (r *RevocationChecker) Validate(ctx context.Context, token string) error {
	if r.cache == nil {
		return nil // no shared cache wired: revocation checking is simply off
	}
	jti, err := jtiFromToken(token)
	if err != nil || jti == "" {
		return nil // no jti to check against — nothing to deny
	}
	_, found, err := r.cache.Get(ctx, revokedJTIPrefix+jti)
	if err != nil {
		return nil // cache unreachable: fail OPEN, matching cache.redis's own failMode:open default
	}
	if found {
		return fmt.Errorf("qafixtures: token %q is revoked", jti)
	}
	return nil
}

// jtiFromToken extracts the `jti` claim from a JWT's payload segment WITHOUT
// verifying the signature — safe here because Validate only ever runs after
// authcore.Validator has already verified it. Malformed input yields ("", nil)
// rather than an error: Validate treats that as "nothing to deny".
func jtiFromToken(token string) (string, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", nil
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", nil
	}
	var claims map[string]any
	if err := json.Unmarshal(payload, &claims); err != nil {
		return "", nil
	}
	jti, _ := claims["jti"].(string)
	return jti, nil
}
