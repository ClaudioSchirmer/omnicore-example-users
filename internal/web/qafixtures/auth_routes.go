//go:build qa

package qafixtures

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"time"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	"github.com/ClaudioSchirmer/omnicore/web/authcore"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"

	infraqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/infra/qafixtures"

	"github.com/gofiber/fiber/v3"
)

// MountAuth exposes the QA-only self-issuance showcase over web/authcore.Issuer
// (wired into d.Issuer from auth.issuer in yaml — see bootstrap/auth_feature.go
// + wire_qa.go). There is no password check anywhere here: /login mints for
// WHATEVER subject the caller names, exactly like the framework's own stance
// (Issue/IssueWithRefresh mint for a subject the CALLER already decided is
// authentic — see docs/content/sections/token-issuance.html). Proving that is
// the caller's job everywhere except this QA fixture, which exists to prove
// the ISSUER mechanics, not a login form.
//
//	POST /qa/auth/login          {subject, permissions?, audience?, ttl_seconds?} -> access+refresh
//	POST /qa/auth/refresh        {refresh_token, permissions?}      -> access+refresh (rotated)
//	POST /qa/auth/logout         {refresh_token}                    -> revokes the WHOLE family
//	POST /qa/auth/revoke-access  {jti, ttl_seconds}                 -> denylists a live access token
//	GET  /qa/auth/whoami         (bearer)                           -> the validated Identity
//	GET  /qa/auth/ttl                                               -> the three live TTLs
//	POST /qa/auth/ttl            {token_ttl_seconds?, …}            -> retunes them at runtime
//
// login/refresh/logout/revoke-access are Public (no bearer — a login route
// cannot require what it is about to grant) and declared in the derived
// yaml's auth.publicRoutes; whoami requires a valid bearer AND the
// "auth:read" permission (auth.authorization.enabled in the derived yaml),
// so the suite can also exercise the permission-denied path with a token
// that carries no permissions claim.
func MountAuth(app *fiber.App, d bootstrap.Deps, store *infraqa.RefreshTokenStore, checker *infraqa.RevocationChecker) {
	g := app.Group("/qa/auth")

	fwopenapi.MountRaw(d.OpenAPIRegistry, g, fiber.MethodPost, "/login",
		loginHandler(d),
		fwopenapi.RawSpec{Summary: "QA-only self-issued login (no password check)", Tags: []string{"QA-Auth"}, Hidden: true, Public: true})

	fwopenapi.MountRaw(d.OpenAPIRegistry, g, fiber.MethodPost, "/refresh",
		refreshHandler(d),
		fwopenapi.RawSpec{Summary: "Redeem + rotate a refresh token", Tags: []string{"QA-Auth"}, Hidden: true, Public: true})

	fwopenapi.MountRaw(d.OpenAPIRegistry, g, fiber.MethodPost, "/logout",
		logoutHandler(store),
		fwopenapi.RawSpec{Summary: "Revoke a refresh token's whole family", Tags: []string{"QA-Auth"}, Hidden: true, Public: true})

	fwopenapi.MountRaw(d.OpenAPIRegistry, g, fiber.MethodPost, "/revoke-access",
		revokeAccessHandler(checker),
		fwopenapi.RawSpec{Summary: "Denylist a live access token by jti", Tags: []string{"QA-Auth"}, Hidden: true, Public: true})

	fwopenapi.MountRaw(d.OpenAPIRegistry, g, fiber.MethodGet, "/whoami",
		whoamiHandler(),
		fwopenapi.RawSpec{Summary: "Return the validated Identity", Tags: []string{"QA-Auth"}, Hidden: true},
		fwopenapi.RequirePermission("auth:read"))

	fwopenapi.MountRaw(d.OpenAPIRegistry, g, fiber.MethodGet, "/ttl",
		readTTLHandler(d),
		fwopenapi.RawSpec{Summary: "Read the Issuer's three live TTLs", Tags: []string{"QA-Auth"}, Hidden: true, Public: true})

	fwopenapi.MountRaw(d.OpenAPIRegistry, g, fiber.MethodPost, "/ttl",
		writeTTLHandler(d),
		fwopenapi.RawSpec{Summary: "Retune the Issuer's TTLs at runtime", Tags: []string{"QA-Auth"}, Hidden: true, Public: true})
}

// ─── request/response shapes ─────────────────────────────────────────────────

type loginRequest struct {
	Subject     string   `json:"subject"`
	Permissions []string `json:"permissions,omitempty"`
	Audience    []string `json:"audience,omitempty"`
	// TTLSeconds feeds authcore.TokenRequest.TTL — the per-token override,
	// silently capped by the Issuer's MaxTokenTTL. Zero (absent) means the
	// Issuer's own default applies.
	TTLSeconds int `json:"ttl_seconds,omitempty"`
}

type refreshRequest struct {
	RefreshToken string   `json:"refresh_token"`
	Permissions  []string `json:"permissions,omitempty"`
}

type logoutRequest struct {
	RefreshToken string `json:"refresh_token"`
}

type revokeAccessRequest struct {
	JTI        string `json:"jti"`
	TTLSeconds int    `json:"ttl_seconds"`
}

type tokenPairResponse struct {
	AccessToken    string     `json:"access_token"`
	ExpiresAt      time.Time  `json:"expires_at"`
	JTI            string     `json:"jti"`
	RefreshToken   string     `json:"refresh_token,omitempty"`
	RefreshExpires *time.Time `json:"refresh_expires_at,omitempty"`
}

// ttlRequest retunes the Issuer at runtime. Every field is a pointer so an
// absent key is distinguishable from an explicit 0 — the suite has to be able
// to send 0 and see it REJECTED (removing the ceiling is not a retune).
type ttlRequest struct {
	TokenTTLSeconds        *int `json:"token_ttl_seconds,omitempty"`
	MaxTokenTTLSeconds     *int `json:"max_token_ttl_seconds,omitempty"`
	RefreshTokenTTLSeconds *int `json:"refresh_token_ttl_seconds,omitempty"`
}

type ttlResponse struct {
	TokenTTLSeconds        int `json:"token_ttl_seconds"`
	MaxTokenTTLSeconds     int `json:"max_token_ttl_seconds"`
	RefreshTokenTTLSeconds int `json:"refresh_token_ttl_seconds"`
}

type revokedResponse struct {
	Revoked bool `json:"revoked"`
}

type whoamiResponse struct {
	Subject string         `json:"subject"`
	Issuer  string         `json:"issuer"`
	Claims  map[string]any `json:"claims"`
}

// ─── handlers ─────────────────────────────────────────────────────────────────

func loginHandler(d bootstrap.Deps) fiber.Handler {
	return func(c fiber.Ctx) error {
		var req loginRequest
		if err := json.Unmarshal(c.Body(), &req); err != nil {
			return respondAuthBadBody(c, err)
		}
		if req.Subject == "" {
			return respondAuthBadRequest(c, "subject", "subject is required")
		}
		if d.Issuer == nil {
			return respondAuthUnavailable(c)
		}
		claims := claimsFromPermissions(req.Permissions)

		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)
		access, refresh, err := d.Issuer.IssueWithRefresh(appCtx, authcore.TokenRequest{
			Subject: req.Subject, Audience: req.Audience, Claims: claims,
			TTL: time.Duration(req.TTLSeconds) * time.Second,
		})
		if err != nil {
			return respondAuthError(c, err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, tokenPairResponse{
			AccessToken: access.Token, ExpiresAt: access.ExpiresAt, JTI: access.JTI,
			RefreshToken: refresh.Value, RefreshExpires: &refresh.ExpiresAt,
		})
	}
}

func refreshHandler(d bootstrap.Deps) fiber.Handler {
	return func(c fiber.Ctx) error {
		var req refreshRequest
		if err := json.Unmarshal(c.Body(), &req); err != nil {
			return respondAuthBadBody(c, err)
		}
		if req.RefreshToken == "" {
			return respondAuthBadRequest(c, "refresh_token", "refresh_token is required")
		}
		if d.Issuer == nil {
			return respondAuthUnavailable(c)
		}
		claims := claimsFromPermissions(req.Permissions)

		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)
		access, refresh, err := d.Issuer.RedeemRefreshToken(appCtx, req.RefreshToken, claims)
		if err != nil {
			return respondAuthError(c, err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, tokenPairResponse{
			AccessToken: access.Token, ExpiresAt: access.ExpiresAt, JTI: access.JTI,
			RefreshToken: refresh.Value, RefreshExpires: &refresh.ExpiresAt,
		})
	}
}

// readTTLHandler / writeTTLHandler expose authcore.Issuer's runtime TTL seam.
// A real service would put these behind the same protection a password-change
// route gets — whoever can raise maxTokenTtlSeconds can mint near-permanent
// tokens. They are Public here for the same reason /qa/auth/revoke-access is:
// this fixture exists to prove the MECHANICS, not to model an admin console.
func readTTLHandler(d bootstrap.Deps) fiber.Handler {
	return func(c fiber.Ctx) error {
		if d.Issuer == nil {
			return respondAuthUnavailable(c)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, currentTTLs(d))
	}
}

func writeTTLHandler(d bootstrap.Deps) fiber.Handler {
	return func(c fiber.Ctx) error {
		var req ttlRequest
		if err := json.Unmarshal(c.Body(), &req); err != nil {
			return respondAuthBadBody(c, err)
		}
		if d.Issuer == nil {
			return respondAuthUnavailable(c)
		}

		// The ceiling invariant (max >= default) means one order works when
		// the pair moves up and the other when it moves down: raising the
		// ceiling first makes room for a bigger default, lowering the default
		// first makes room for a smaller ceiling. Pick per request instead of
		// forcing the caller into two round trips.
		ceilingFirst := req.MaxTokenTTLSeconds != nil &&
			time.Duration(*req.MaxTokenTTLSeconds)*time.Second >= d.Issuer.TokenTTL()

		apply := []struct {
			field string
			secs  *int
			set   func(time.Duration) error
		}{
			{"max_token_ttl_seconds", req.MaxTokenTTLSeconds, d.Issuer.SetMaxTokenTTL},
			{"token_ttl_seconds", req.TokenTTLSeconds, d.Issuer.SetTokenTTL},
			{"refresh_token_ttl_seconds", req.RefreshTokenTTLSeconds, d.Issuer.SetRefreshTokenTTL},
		}
		if !ceilingFirst {
			apply[0], apply[1] = apply[1], apply[0]
		}

		for _, step := range apply {
			if step.secs == nil {
				continue
			}
			if err := step.set(time.Duration(*step.secs) * time.Second); err != nil {
				return respondAuthBadRequest(c, step.field, err.Error())
			}
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, currentTTLs(d))
	}
}

func currentTTLs(d bootstrap.Deps) ttlResponse {
	return ttlResponse{
		TokenTTLSeconds:        int(d.Issuer.TokenTTL().Seconds()),
		MaxTokenTTLSeconds:     int(d.Issuer.MaxTokenTTL().Seconds()),
		RefreshTokenTTLSeconds: int(d.Issuer.RefreshTokenTTL().Seconds()),
	}
}

// logoutHandler resolves the refresh token's FamilyID by hashing the raw
// value the same way authcore.Issuer does (sha256 hex — see hashRefreshValue
// below) and revokes the whole family. A service that wants this capability
// for real would keep the SAME hash algorithm the Issuer uses internally,
// since RefreshTokenStore only ever sees hashes, never raw values.
func logoutHandler(store *infraqa.RefreshTokenStore) fiber.Handler {
	return func(c fiber.Ctx) error {
		var req logoutRequest
		if err := json.Unmarshal(c.Body(), &req); err != nil {
			return respondAuthBadBody(c, err)
		}
		if req.RefreshToken == "" {
			return respondAuthBadRequest(c, "refresh_token", "refresh_token is required")
		}
		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)
		rec, err := store.Lookup(appCtx, hashRefreshValue(req.RefreshToken))
		if err != nil {
			return respondAuthError(c, err)
		}
		if err := store.RevokeFamily(appCtx, rec.FamilyID); err != nil {
			return respondAuthError(c, err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, revokedResponse{Revoked: true})
	}
}

func revokeAccessHandler(checker *infraqa.RevocationChecker) fiber.Handler {
	return func(c fiber.Ctx) error {
		var req revokeAccessRequest
		if err := json.Unmarshal(c.Body(), &req); err != nil {
			return respondAuthBadBody(c, err)
		}
		if req.JTI == "" {
			return respondAuthBadRequest(c, "jti", "jti is required")
		}
		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)
		if err := checker.Revoke(appCtx, req.JTI, time.Duration(req.TTLSeconds)*time.Second); err != nil {
			return respondAuthError(c, err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, revokedResponse{Revoked: true})
	}
}

func whoamiHandler() fiber.Handler {
	return func(c fiber.Ctx) error {
		id := fwweb.AppContext(c).Identity()
		if id == nil {
			return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{"success": false, "status": fiber.StatusUnauthorized})
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, whoamiResponse{
			Subject: id.Subject, Issuer: id.Issuer, Claims: id.Claims,
		})
	}
}

// ─── helpers ──────────────────────────────────────────────────────────────────

func claimsFromPermissions(perms []string) map[string]any {
	if len(perms) == 0 {
		return nil
	}
	return map[string]any{"permissions": perms}
}

// hashRefreshValue MUST match authcore's internal hashing (sha256 hex of the
// raw opaque value) — the RefreshTokenStore only ever stores/looks up by this
// hash, so a mismatch here would make logout unable to find its own tokens.
func hashRefreshValue(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func respondAuthBadBody(c fiber.Ctx, err error) error {
	return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
		"success": false, "status": fiber.StatusBadRequest,
		"errors": []fiber.Map{{"context": "Auth", "messages": []fiber.Map{{
			"notificationKey": "SchemaViolationNotification", "field": "body", "message": "Invalid JSON body: " + err.Error(),
		}}}},
	})
}

func respondAuthBadRequest(c fiber.Ctx, field, msg string) error {
	return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
		"success": false, "status": fiber.StatusBadRequest,
		"errors": []fiber.Map{{"context": "Auth", "messages": []fiber.Map{{
			"notificationKey": "RequiredFieldNotification", "field": field, "message": msg,
		}}}},
	})
}

func respondAuthUnavailable(c fiber.Ctx) error {
	return c.Status(fiber.StatusServiceUnavailable).JSON(fiber.Map{
		"success": false, "status": fiber.StatusServiceUnavailable,
		"errors": []fiber.Map{{"context": "Auth", "messages": []fiber.Map{{
			"notificationKey": "ServiceUnavailableNotification", "message": "auth.issuer is not enabled",
		}}}},
	})
}

func respondAuthError(c fiber.Ctx, err error) error {
	return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
		"success": false, "status": fiber.StatusUnauthorized,
		"errors": []fiber.Map{{"context": "Auth", "messages": []fiber.Map{{
			"notificationKey": "InvalidTokenNotification", "message": err.Error(),
		}}}},
	})
}
