//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	"github.com/ClaudioSchirmer/omnicore/web/export"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"

	"github.com/gofiber/fiber/v3"
)

// MountCatalogs registers the NORMAL-view embed showcase under /qa/catalogs:
// create (a plain aggregate insert) and read the composed `qa_catalog_view`
// document by id (flat catalog + FeaturedItem 1:1 embed + Items 1:N EmbedMany,
// both external, from the SAME upstream_items projection the shared-base
// AccountView embeds). It proves the external Embed/EmbedMany compose on a
// regular query.View, not only a SharedBaseView.
func MountCatalogs(
	app *fiber.App,
	repo persistence.ScopedRepository[*qadomain.Catalog],
	view *query.ViewDefinition,
	d bootstrap.Deps,
) {
	g := app.Group("/qa/catalogs")
	viewName := view.Name()

	insertH, insertSpec := fwweb.HandleCommandWithBodySpec(d.Pipeline,
		InsertCatalogRequest{},
		InsertCatalogResponse{}.FromResult,
		&handlers.InsertCommandHandler[*qadomain.Catalog, *appqa.InsertCatalogCommand, appqa.CatalogResult]{
			Repo: repo,
		}, fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPost, "/",
		insertH, insertSpec,
		fwopenapi.Doc{
			Summary:     "Create a catalog (normal view + external embeds)",
			Description: "Creates a qa_catalogs row. Pass `featuredItemId` (an existing item id) to wire the 1:1 embed. The returned `id` is the catalog id — use it as items' `catalogId` to populate the 1:N Items segment.",
			Tags:        []string{"QA Catalogs (normal-view embed)"},
		},
		fwopenapi.RequirePermission("gadgets:write"))

	byIDH, byIDSpec := fwweb.HandleQueryByIDSpec(d.Pipeline,
		FindCatalogByIDRequest{},
		fwresponses.AutoFromDoc[FindCatalogByIDResponse],
		&handlers.FindByIDQueryHandler[*appqa.FindCatalogByIDQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:id",
		byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary:     "Get a catalog by id (normal view + external embeds)",
			Description: "Reads the `qa_catalog_view` regular view document: the flat catalog, the 1:1 `featuredItem` embed (null until the referenced upstream_items doc materializes/ripples), and the 1:N `items` array (upstream_items whose catalog_id equals this catalog). Proves external Embed AND EmbedMany compose on a normal query.View.",
			Tags:        []string{"QA Catalogs (normal-view embed)"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	listH, listSpec := fwweb.HandleQueryWithParamsSpec(d.Pipeline,
		FindCatalogsRequest{},
		fwresponses.AutoFromDoc[FindCatalogsListResponse],
		&handlers.FindByParamsQueryHandler[*appqa.FindCatalogsQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List catalogs (paged; filter/sort/fields into embeds)",
			Description: "Paged read of `qa_catalog_view` (a normal view). Root filter (`name`) and embed-segment filters (`featuredItem.label`, `items.label`) select ROWS over the materialized document; `?sort=`, `?fields=` (incl. into segments), pagination and `?onlyTotal` apply as on any view.",
			Tags:        []string{"QA Catalogs (normal-view embed)"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	csvH, csvSpec := fwweb.HandleQueryAsCSVSpec(d.Pipeline,
		FindCatalogsRequest{}, view, d.Export,
		&handlers.FindByParamsQueryHandler[*appqa.FindCatalogsQuery]{Reader: d.ViewReader, View: viewName},
		export.WithDelimiter(','))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/catalogs.csv",
		csvH, csvSpec,
		fwopenapi.Doc{
			Summary: "Export catalogs as CSV (root + embed segment branches)",
			Tags:    []string{"QA Catalogs (normal-view embed)"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	xlsxH, xlsxSpec := fwweb.HandleQueryAsXLSXSpec(d.Pipeline,
		FindCatalogsRequest{}, view, d.Export,
		&handlers.FindByParamsQueryHandler[*appqa.FindCatalogsQuery]{Reader: d.ViewReader, View: viewName},
		export.WithSheetName("Catalogs"))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/catalogs.xlsx",
		xlsxH, xlsxSpec,
		fwopenapi.Doc{
			Summary: "Export catalogs as Excel (root + embed segment branches)",
			Tags:    []string{"QA Catalogs (normal-view embed)"},
		},
		fwopenapi.RequirePermission("gadgets:read"))
}

// ─── Create DTOs ─────────────────────────────────────────────────────────────

// InsertCatalogRequest is the JSON body of POST /qa/catalogs.
type InsertCatalogRequest struct {
	Name           string  `json:"name"                     example:"Summer Collection"`
	FeaturedItemID *string `json:"featuredItemId,omitempty" example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
}

func (r InsertCatalogRequest) ToCommand() *appqa.InsertCatalogCommand {
	return &appqa.InsertCatalogCommand{Name: r.Name, FeaturedItemID: r.FeaturedItemID}
}

// InsertCatalogResponse is the wire shape of a successful catalog insert.
type InsertCatalogResponse struct {
	ID             string  `json:"id"`
	Name           string  `json:"name"`
	FeaturedItemID *string `json:"featuredItemId,omitempty"`
}

func (InsertCatalogResponse) FromResult(r appqa.CatalogResult) InsertCatalogResponse {
	return InsertCatalogResponse{ID: r.ID.String(), Name: r.Name, FeaturedItemID: r.FeaturedItemID}
}

// ─── Read DTOs ───────────────────────────────────────────────────────────────

// FindCatalogByIDRequest is the wire allowlist of GET /qa/catalogs/:id.
type FindCatalogByIDRequest struct {
	IncludeArchived *bool `query:"includeArchived"`
}

func (r FindCatalogByIDRequest) ToQuery() *appqa.FindCatalogByIDQuery {
	arch := false
	if r.IncludeArchived != nil {
		arch = *r.IncludeArchived
	}
	return &appqa.FindCatalogByIDQuery{IncludeArchived: arch}
}

// FindCatalogByIDResponse is the composed normal-view projection. AutoFromDoc
// keys the embed segments by their Go .As names (FeaturedItem / Items); the
// segment shape (ItemSegmentOutput) is shared with the shared-base AccountView.
type FindCatalogByIDResponse struct {
	ID             string              `json:"id"`
	Name           string              `json:"name"`
	FeaturedItemID *string             `json:"featuredItemId,omitempty"`
	FeaturedItem   *ItemSegmentOutput  `json:"featuredItem,omitempty"`
	Items          []ItemSegmentOutput `json:"items,omitempty"`
}

// ─── List DTOs (normal view — filter/sort/fields/pagination into embeds) ─────

// FindCatalogsRequest is the wire allowlist of GET /qa/catalogs (+ .csv/.xlsx).
// It reuses the shared ItemSegmentFilter group (declared in account_routes.go).
type FindCatalogsRequest struct {
	Name *string `query:"name" filter:"eq,icontains"`

	FeaturedItem ItemSegmentFilter `query:"featuredItem"`
	Items        ItemSegmentFilter `query:"items"`

	Limit           *int64  `query:"limit"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	Sort            *string `query:"sort"`
	Fields          *string `query:"fields"`
	OnlyTotal       *bool   `query:"onlyTotal"`
	IncludeArchived *bool   `query:"includeArchived"`
}

func (r FindCatalogsRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindCatalogsQuery {
	return &appqa.FindCatalogsQuery{Criteria: criteria}
}

// FindCatalogsListResponse is the per-item wire projection of the paged catalog
// list — pointer fields for `?fields=` pruning into the embed segments.
type FindCatalogsListResponse struct {
	ID             *string             `json:"id,omitempty"`
	Name           *string             `json:"name,omitempty"`
	FeaturedItemID *string             `json:"featuredItemId,omitempty"`
	FeaturedItem   *ItemSegmentOutput  `json:"featuredItem,omitempty"`
	Items          []ItemSegmentOutput `json:"items,omitempty"`
}
