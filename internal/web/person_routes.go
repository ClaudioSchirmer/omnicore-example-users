package web

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	"github.com/ClaudioSchirmer/omnicore/web/export"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/web/requests"

	"github.com/gofiber/fiber/v3"
)

// MountPersons registers the READ-ONLY routes over the all-in-one person view
// (the SharedBaseView rooted at the shared Person identity). There are no
// write routes here on purpose: a person is written THROUGH its roles
// (/users/*, /employees/*) — this surface only reads the composed aggregate.
func MountPersons(
	app *fiber.App,
	view *query.ViewDefinition,
	d bootstrap.Deps,
) {
	persons := app.Group("/persons")
	viewName := view.Name()

	listH, listSpec := fwweb.HandleQueryWithParamsSpec(d.Pipeline,
		requests.FindPersonsByParamsRequest{},
		fwresponses.AutoFromDoc[requests.FindPersonsByParamsResponse],
		&handlers.FindByParamsQueryHandler[*appqueries.FindPersonByParamsQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, persons, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List persons (all-in-one identity, paged + filter)",
			Description: "Paged read against the `persons` Mongo view — the SharedBaseView projecting each shared Person identity with EVERY role: shared fields flat at the root, the shared addresses[], and one optional sub-object per role (`user` with its notification flags, `employee` with its bank facet + dependents/jobHistories). Filters cover root fields (name/email/document), address paths, and role paths (`?user.userName=…`, `?employee.employeeNumber=…`, `?employee.dependents.relationship=…`). A person missing a role simply omits that key; an archived role is omitted on default reads and surfaces (with `deletedAt`) under `?includeArchived=true`; the person itself hides only when every role is archived. Same reserved keys as GET /users.",
			Tags:        []string{"Persons"},
		},
		fwopenapi.RequirePermission("persons:read"))

	byIDH, byIDSpec := fwweb.HandleQueryByIDSpec(d.Pipeline,
		requests.FindPersonByIDRequest{},
		fwresponses.AutoFromDoc[requests.FindPersonByIDResponse],
		&handlers.FindByIDQueryHandler[*appqueries.FindPersonByIDQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, persons, fiber.MethodGet, "/:id",
		byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary:     "Get a person by id (all-in-one identity)",
			Description: "Fetches the composed person document by the shared identity's deterministic id (`UUIDv5(document)`) — the same id the shared-PK roles carry, so a user id resolves its person directly. Returns the root identity + addresses[] + each role sub-object present for that person. Only `?includeArchived=true` is recognized. 404 when the identity is absent or every role is archived and `includeArchived` was not requested.",
			Tags:        []string{"Persons"},
		},
		fwopenapi.RequirePermission("persons:read"))

	// CSV export — same Request DTO and view query handler as GET /persons,
	// rendered hierarchically (root at column A; addresses and each role branch
	// one level in; a role's own collections one level further).
	csvH, csvSpec := fwweb.HandleQueryAsCSVSpec(d.Pipeline,
		requests.FindPersonsByParamsRequest{},
		view,
		d.Export,
		&handlers.FindByParamsQueryHandler[*appqueries.FindPersonByParamsQuery]{
			Reader: d.ViewReader, View: viewName,
		},
		export.WithDelimiter(','))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/persons.csv",
		csvH, csvSpec,
		fwopenapi.Doc{
			Summary:     "Export persons as CSV",
			Description: "Streams the same `persons` view read as GET /persons — same filter allowlist, `?search`, `?sort`, `?includeArchived`, `?fields=` — as a hierarchical CSV: the shared identity at column A, addresses and each role branch one level in (role fields + siblings; the employee branch nests its dependents/jobHistories one level further). The role branches never repeat the shared columns. Pagination is ignored — the full filtered set streams capped at `query.maxExportRows`.",
			Tags:        []string{"Persons"},
		},
		fwopenapi.RequirePermission("persons:read"))

	// XLSX export — identical surface, different encoder.
	xlsxH, xlsxSpec := fwweb.HandleQueryAsXLSXSpec(d.Pipeline,
		requests.FindPersonsByParamsRequest{},
		view,
		d.Export,
		&handlers.FindByParamsQueryHandler[*appqueries.FindPersonByParamsQuery]{
			Reader: d.ViewReader, View: viewName,
		},
		export.WithSheetName("Persons"))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/persons.xlsx",
		xlsxH, xlsxSpec,
		fwopenapi.Doc{
			Summary:     "Export persons as Excel (.xlsx)",
			Description: "Same surface as `GET /persons.csv` — same filter allowlist, `?fields=`, `?search`, `?sort`, `?includeArchived`, same hierarchical layout — serialized as an Excel workbook.",
			Tags:        []string{"Persons"},
		},
		fwopenapi.RequirePermission("persons:read"))
}
