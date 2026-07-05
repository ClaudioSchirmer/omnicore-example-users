package main

import (
	"github.com/ClaudioSchirmer/omnicore/application/translation"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwgraphql "github.com/ClaudioSchirmer/omnicore/web/graphql"
	"github.com/ClaudioSchirmer/omnicore/web/openapi"

	apptrans "github.com/ClaudioSchirmer/omnicore-example-users/application/translations"
)

// Wire concentrates translations + features that the service exposes. Called
// by main.go via bootstrap.Run(Wire). /health comes from the framework
// automatically — no need to declare it here.
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

	// GraphQL is ONE surface (POST /graphql) backed by ONE registry, created
	// here like the OpenAPI registry. Registration is cumulative: each feature
	// contributes its fields into the same graph. Served separately from REST —
	// never in the Swagger document; serving knobs live under graphql: in the YAML.
	gql := fwgraphql.New(d.Pipeline)
	users.MountGraphQL(gql, d)
	employees.MountGraphQL(gql, d)
	persons.MountGraphQL(gql, d)
	// QA-only GraphQL fields (no-op in the canonical build) — the same
	// build-tag seam qaFeatures uses, applied to the shared registry.
	qaMountGraphQL(gql, d)

	return bootstrap.Wiring{
		Translations: []translation.Module{
			apptrans.PTBR(), apptrans.ENG(), apptrans.ESP(), apptrans.FRA(),
			apptrans.DEU(), apptrans.ITA(), apptrans.NLD(),
		},
		// qaFeatures(d) appends the QA-only fixtures (Gadget) when built with
		// the `qa` build tag; it is nil in the canonical (non-qa) build. This
		// append is the ONLY canonical touch for the QA fixtures — everything
		// else lives under //go:build qa in qafixtures/ subfolders.
		Features: append([]bootstrap.Feature{
			users,
			employees,
			persons,
			NewUserCustomFeature(d),
			NewAuditFeature(),
		}, qaFeatures(d)...),
		OpenAPI: &openapi.Config{
			Title:            "OmniCore Example Users",
			Version:          "0.1.0",
			Description:      "Reference microservice exercising every OmniCore feature: CRUD with addresses as an aggregate child, manual showcase, outbound HTTP showcases, and the auth identity demo.",
			LanguageSelector: true,
		},
		GraphQL: gql,
	}
}
