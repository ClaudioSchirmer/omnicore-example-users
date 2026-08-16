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
func qaAuthWiring(d bootstrap.Deps) (bootstrap.Feature, authcore.RefreshTokenStore, authcore.TokenChecker) {
	if err := infraqa.ProvisionRefreshTokenTable(context.Background(), d.DB); err != nil {
		panic("qaAuthWiring: provisioning qa_refresh_tokens failed: " + err.Error())
	}
	store := infraqa.NewRefreshTokenStore(d.DB)
	checker := infraqa.NewRevocationChecker(d.SharedCache)
	return NewAuthFeature(store, checker), store, checker
}
