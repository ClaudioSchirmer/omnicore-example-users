package main

import (
	"github.com/ClaudioSchirmer/omnicore/application/translation"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
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
	return bootstrap.Wiring{
		Translations: []translation.Module{
			apptrans.PTBR(), apptrans.ENG(), apptrans.ESP(), apptrans.FRA(),
			apptrans.DEU(), apptrans.ITA(), apptrans.NLD(),
		},
		Features: []bootstrap.Feature{
			NewUsersFeature(d),
			NewShowcaseFeature(d),
			NewAdminFeature(),
			NewAuditFeature(),
		},
		OpenAPI: &openapi.Config{
			Title:       "OmniCore Example Users",
			Version:     "0.1.0",
			Description: "Reference microservice exercising every OmniCore feature: CRUD with addresses as an aggregate child, manual showcase, outbound HTTP showcases, and the auth identity demo.",
            LanguageSelector: true,
		},
	}
}
