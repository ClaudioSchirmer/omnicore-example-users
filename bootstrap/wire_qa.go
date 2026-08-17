//go:build qa

package main

import (
	"context"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/web/authcore"

	infraqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/infra/qafixtures"
)

// qaFeatures returns the QA-only features appended to the canonical set when
// the binary is built with the `qa` build tag. This is the only difference in
// the wired feature list between the canonical and the QA builds.
func qaFeatures(d bootstrap.Deps) []bootstrap.Feature {
	return []bootstrap.Feature{
		NewShowcaseFeature(d),
		NewAdminFeature(),
		NewGadgetFeature(d),
		NewLensFeature(d),
		NewLensFieldsFeature(),
		NewAccountFeature(d),
		NewProductFeature(d),
		NewWidgetFeature(d),
		NewContractFeature(d),
	}
}

// qaAuthWiring provisions qa_refresh_tokens (idempotent) and constructs the
// AuthFeature + the SAME RefreshTokenStore/TokenChecker instances Wire()
// hands to Wiring.RefreshTokenStore/Wiring.TokenChecker — one construction
// site, so Deps.Issuer (built by the framework FROM Wiring.RefreshTokenStore)
// and the /qa/auth/logout + /qa/auth/revoke-access handlers always agree on
// which store/checker they are talking to. Kept separate from qaFeatures
// because it also needs to hand two values back to Wire() beyond the Feature
// itself.
// The two SEAMS are wired only when the profile declares `auth.issuer:` — the
// self-issuance posture the AuthFeature exists to exercise. The routes are
// always mounted (they are qa surface), but a TokenChecker handed to the
// middleware SUPERSEDES `auth.externalValidator` by framework design
// (web.AuthOptions: "Superseded by TokenChecker when both are set"), and this
// service's in-process denylist knows nothing about a revocation performed at
// the IdP. Wiring it unconditionally therefore silently disabled the external
// validator on every qa-binary profile — including `prd-external*`, whose whole
// point is that a Keycloak-revoked token must stop working, which is what
// qa/auth.sh asserts. The two qa fixtures were contradicting each other; the
// profile is what tells them apart.
func qaAuthWiring(d bootstrap.Deps) (bootstrap.Feature, authcore.RefreshTokenStore, authcore.TokenChecker) {
	if err := infraqa.ProvisionRefreshTokenTable(context.Background(), d.DB); err != nil {
		panic("qaAuthWiring: provisioning qa_refresh_tokens failed: " + err.Error())
	}
	store := infraqa.NewRefreshTokenStore(d.DB)
	checker := infraqa.NewRevocationChecker(d.SharedCache)
	feature := NewAuthFeature(store, checker)
	if d.Config == nil || d.Config.Auth.Issuer == nil {
		return feature, nil, nil
	}
	return feature, store, checker
}
