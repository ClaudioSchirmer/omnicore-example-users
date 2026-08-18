//go:build qa

// This file mounts the READ-ONLY mirror routes over the RelationalSource views.
// They reuse the EXACT same Request/Response DTOs and query handlers as the Mongo
// originals — only the `View:` name (and the URL prefix, `/qa/rel/...`) differ —
// so the `relational_view` suite drives the same asserts against a relationally
// served document. Write verbs stay on the canonical `/qa/gadgets` + `/qa/lens-*`
// routes (one source of truth for writes); these surfaces only read. Present only
// in the `qa` build.
package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	"github.com/ClaudioSchirmer/omnicore/web/export"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"

	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	"github.com/gofiber/fiber/v3"
)

// MountGadgetsRel mounts the relational-source read twin of the gadgets surface:
//
//	GET /qa/rel/gadgets            list (full filter vocabulary, served from the SoR)
//	GET /qa/rel/gadgets/:id        by id
//	GET /qa/rel/gadgets.csv        CSV export
//	GET /qa/rel/gadgets.xlsx       Excel export
//	GET /qa/rel/gadgets-capped     list against the MaxLimit(5)/MaxExportRows(3) twin
//	GET /qa/rel/gadgets-capped.csv CSV export (truncated at the export ceiling)
//
// listView/cappedView are the RelationalSource ViewDefinitions (they double as the
// ExportView plan source for the CSV/XLSX routes).
func MountGadgetsRel(
	app *fiber.App,
	listView *query.ViewDefinition,
	cappedView *query.ViewDefinition,
	d bootstrap.Deps,
) {
	g := app.Group("/qa/rel/gadgets")

	listH, listSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindGadgetsRequest{},
		FindGadgetsResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery, appqa.FindGadgetsResult]{
			Reader: d.ViewReader, View: listView.Name(),
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List gadgets from the relational SoR (RelationalSource mirror)",
			Description: "Byte-parity twin of GET /qa/gadgets, served directly from the relational backend via RelationalSource. Same filter/sort/fields/pagination vocabulary on root fields; `?search=` and any child/sibling-field filter or sort return 400 RelationalCapabilityNotification (a root SELECT cannot express them).",
			Tags:        []string{"QA Relational Views"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	byIDH, byIDSpec := fwweb.QueryByIDSpec(d.Pipeline,
		FindGadgetByIDRequest{},
		FindGadgetByIDResponse{}.FromResult,
		&handlers.FindByIDQueryHandler[*appqa.FindGadgetByIDQuery, appqa.FindGadgetByIDResult]{
			Reader: d.ViewReader, View: listView.Name(),
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:id",
		byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary:     "Get a gadget by id from the relational SoR",
			Description: "Relational twin of GET /qa/gadgets/:id (criteria.ByID + Limit 1). Only `?includeArchived=true` is recognized. 404 when absent.",
			Tags:        []string{"QA Relational Views"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	csvH, csvSpec := fwweb.QueryAsCSVSpec(d.Pipeline,
		FindGadgetsRequest{},
		FindGadgetsResponse{}.FromResult,
		listView, d.Export,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery, appqa.FindGadgetsResult]{Reader: d.ViewReader, View: listView.Name()},
		export.WithDelimiter(','))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/rel/gadgets.csv",
		csvH, csvSpec,
		fwopenapi.Doc{
			Summary: "Export relational gadgets as CSV",
			Tags:    []string{"QA Relational Views"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	xlsxH, xlsxSpec := fwweb.QueryAsXLSXSpec(d.Pipeline,
		FindGadgetsRequest{},
		FindGadgetsResponse{}.FromResult,
		listView, d.Export,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery, appqa.FindGadgetsResult]{Reader: d.ViewReader, View: listView.Name()},
		export.WithSheetName("Gadgets"))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/rel/gadgets.xlsx",
		xlsxH, xlsxSpec,
		fwopenapi.Doc{
			Summary: "Export relational gadgets as Excel",
			Tags:    []string{"QA Relational Views"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	// Capped twin — proves the relational reader honors MaxLimit + MaxExportRows.
	cg := app.Group("/qa/rel/gadgets-capped")
	cListH, cListSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindGadgetsRequest{},
		FindGadgetsResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery, appqa.FindGadgetsResult]{
			Reader: d.ViewReader, View: cappedView.Name(),
		})
	fwopenapi.Mount(d.OpenAPIRegistry, cg, fiber.MethodGet, "/",
		cListH, cListSpec,
		fwopenapi.Doc{
			Summary:     "List relational gadgets with a per-view MaxLimit(5)",
			Description: "Relational twin carrying MaxLimit(5): `?first=` over 5 returns 400 LimitExceededNotification, identical to the Mongo gadgets_capped view.",
			Tags:        []string{"QA Relational Views"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	cCsvH, cCsvSpec := fwweb.QueryAsCSVSpec(d.Pipeline,
		FindGadgetsRequest{},
		FindGadgetsResponse{}.FromResult,
		cappedView, d.Export,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery, appqa.FindGadgetsResult]{Reader: d.ViewReader, View: cappedView.Name()},
		export.WithDelimiter(','))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/rel/gadgets-capped.csv",
		cCsvH, cCsvSpec,
		fwopenapi.Doc{
			Summary: "Export relational capped gadgets as CSV (truncated at MaxExportRows=3)",
			Tags:    []string{"QA Relational Views"},
		},
		fwopenapi.RequirePermission("gadgets:read"))
}

// MountGadgetEvolve mounts a single GET list route over the flippable
// `gadgets_evolve` view (see GadgetEvolveView) so the relational_evolution suite
// can observe reads following the active backing across a mongo↔relational
// transition — the SAME route serves from the Mongo collection or the SoR
// depending on the view's current variant.
func MountGadgetEvolve(app *fiber.App, viewName string, d bootstrap.Deps) {
	g := app.Group("/qa/gadgets-evolve")
	listH, listSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindGadgetsRequest{},
		FindGadgetsResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery, appqa.FindGadgetsResult]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List gadgets_evolve (backing flips mongo↔relational across the evolution suite)",
			Description: "Reads the flippable gadgets_evolve view. Served from the Mongo projection or the relational SoR depending on the view's current variant — the dispatch seam routes by name.",
			Tags:        []string{"QA Relational Views"},
		},
		fwopenapi.RequirePermission("gadgets:read"))
}

// MountLensBrandsRel mounts the relational read twin of the lens-brands surface:
//
//	GET /qa/rel/lens-brands   list (name filter, archive gate) served from the SoR
func MountLensBrandsRel(app *fiber.App, listView *query.ViewDefinition, d bootstrap.Deps) {
	g := app.Group("/qa/rel/lens-brands")

	listH, listSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindLensBrandsRequest{},
		FindLensBrandsResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindLensBrandsQuery, appqa.FindLensBrandsResult]{
			Reader: d.ViewReader, View: listView.Name(),
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List lens brands from the relational SoR (RelationalSource mirror)",
			Description: "Relational twin of GET /qa/lens-brands: `?name=` (eq/contains), archive gate + `?includeArchived`, pagination and `?onlyTotal` served from the SoR.",
			Tags:        []string{"QA Relational Views"},
		},
		fwopenapi.RequirePermission("gadgets:read"))
}
