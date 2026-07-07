//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"

	"github.com/gofiber/fiber/v3"
)

// MountGadgetEmbedded registers the read surface over the COMPOSED gadget view
// (`gadgets_embedded`) under /qa/gadgets-embedded. This is what turns the
// upstream projection from a Mongo-only artifact into something a client can
// actually read: the embedded document is the flat gadget plus the one-to-one
// `upstreamMirror` embed the composer fills from `upstream_gadgets`.
//
//	GET /qa/gadgets-embedded/:id   by id (root gadget + nested upstream mirror)
//
// The request DTO + application query are the SAME view-agnostic types the plain
// gadget by-id read uses (FindGadgetByIDRequest / FindGadgetByIDQuery) — only the
// Response shape (nested mirror) and the target view name differ. The endpoint
// reuses the `gadgets:read` permission so no authz change is needed.
func MountGadgetEmbedded(app *fiber.App, viewName string, d bootstrap.Deps) {
	g := app.Group("/qa/gadgets-embedded")

	byIDH, byIDSpec := fwweb.HandleQueryByIDSpec(d.Pipeline,
		FindGadgetByIDRequest{},
		fwresponses.AutoFromDoc[FindGadgetEmbeddedByIDResponse],
		&handlers.FindByIDQueryHandler[*appqa.FindGadgetByIDQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:id",
		byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary:     "Get an embedded gadget by id (root + upstream mirror)",
			Description: "Fetches the gadget document from the `gadgets_embedded` Mongo view: the flat gadget PLUS the one-to-one `upstreamMirror` embed the composer resolves from the `upstream_gadgets` projection (materialized by the upstream subscriber). The mirror carries only [id, code, name] — the fields that survive the subscription filter — so category/status are absent from it. `upstreamMirror` is omitted entirely until the upstream copy has been materialized and rippled in. Only `?includeArchived=true` is recognized; 404 when the gadget is absent or filtered out.",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:read"))
}
