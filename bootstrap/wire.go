package main

import (
	"github.com/ClaudioSchirmer/omnicore/application/translation"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/web/openapi"

	apptrans "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/translations"
)

// Wire concentrates translations + features that the service exposes. Called
// by main.go via bootstrap.Run(Wire). The /livez + /readyz probes come from the
// framework automatically — no need to declare them here.
//
// OpenAPI is opt-in via Wiring.OpenAPI: setting the field activates
// GET /openapi.json + GET /docs and makes d.OpenAPIRegistry non-nil so the
// MountUsers / MountUsersCustom / MountWhoami / MountShowcase / MountEcho
// helpers can register each route with the documentation layer. Removing
// the field rolls back to a binary that ships without the spec endpoints.
func Wire(d bootstrap.Deps) bootstrap.Wiring {
	users := NewUsersFeature(d)
	employees := NewEmployeesFeature(d)
	persons := NewPersonsFeature(d)

	// authFeature/refreshStore/tokenChecker are all nil in the canonical
	// (non-qa) build — see wire_noqa.go. In the qa build, qaAuthWiring
	// provisions qa_refresh_tokens and wires web/authcore.Issuer's two
	// pluggable seams (RefreshTokenStore, TokenChecker) to the SAME
	// instances the /qa/auth/* routes use directly (logout/revoke-access).
	authFeature, refreshStore, tokenChecker := qaAuthWiring(d)

	// GraphQL and gRPC are NOT wired here: each feature opts into those surfaces
	// by implementing bootstrap.GraphQLFeature / bootstrap.GRPCFeature, and the
	// framework discovers them (like ReadableFeature), builds the single shared
	// registry per surface and serves it. users/employees/persons contribute
	// GraphQL fields; users contributes the gRPC UsersService; the QA GadgetFeature
	// contributes the QA GraphQL/gRPC fixtures — all cumulatively, no hand-wiring.
	// Serving knobs live under graphql:/grpc: in the YAML.

	// qaFeatures(d) appends the QA-only fixtures (Gadget) when built with the
	// `qa` build tag; it is nil in the canonical (non-qa) build. authFeature
	// (nil in the canonical build) is appended separately because it, unlike
	// qaFeatures' members, also needs its store/checker surfaced on Wiring
	// itself (below) — everything here is the ONLY canonical touch for the
	// QA fixtures; the rest lives under //go:build qa in qafixtures/.
	features := append([]bootstrap.Feature{
		users,
		employees,
		persons,
		NewUserCustomFeature(d),
		NewAuditFeature(),
	}, qaFeatures(d)...)
	if authFeature != nil {
		features = append(features, authFeature)
	}

	return bootstrap.Wiring{
		Translations: []translation.Module{
			apptrans.PTBR(), apptrans.ENG(), apptrans.ESP(), apptrans.FRA(),
			apptrans.DEU(), apptrans.ITA(), apptrans.NLD(),
		},
		Features:          features,
		RefreshTokenStore: refreshStore,
		TokenChecker:      tokenChecker,
		OpenAPI: &openapi.Config{
			Title:            "OmniCore Example Users",
			Version:          "0.1.0",
			Description:      "Reference microservice exercising every OmniCore feature: CRUD with addresses as an aggregate child, manual showcase, outbound HTTP showcases, and the auth identity demo.",
			LanguageSelector: true,
		},
	}
}
