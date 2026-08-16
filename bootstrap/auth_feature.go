//go:build qa

package main

import (
	"github.com/ClaudioSchirmer/omnicore/bootstrap"

	infraqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/infra/qafixtures"
	webqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/web/qafixtures"

	"github.com/gofiber/fiber/v3"
)

// AuthFeature mounts the QA-only self-issuance showcase (/qa/auth/*) proving
// web/authcore.Issuer end to end: login mints an access+refresh pair via the
// framework's own Issuer (wired into Deps.Issuer from auth.issuer in the
// derived yaml qa/auth_selfissued.sh boots), refresh redeems/rotates, logout
// revokes a refresh-token family, revoke-access denylists a live access
// token's jti through the in-process TokenChecker seam, and whoami proves
// the SAME service's auth.jwt validates its own self-issued tokens with zero
// issuer-specific code. Mount-only feature — no domain, no repository beyond
// the store, no view. Present only in the `qa` build.
//
// store and checker are constructed exactly once in wire_qa.go's
// qaAuthWiring, which ALSO returns them for Wiring.RefreshTokenStore /
// Wiring.TokenChecker — the same instances Deps.Issuer ends up calling
// through, and the ones /qa/auth/logout and /qa/auth/revoke-access reach for
// directly.
type AuthFeature struct {
	store   *infraqa.RefreshTokenStore
	checker *infraqa.RevocationChecker
}

func NewAuthFeature(store *infraqa.RefreshTokenStore, checker *infraqa.RevocationChecker) *AuthFeature {
	return &AuthFeature{store: store, checker: checker}
}

func (f *AuthFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	webqa.MountAuth(app, d, f.store, f.checker)
}
