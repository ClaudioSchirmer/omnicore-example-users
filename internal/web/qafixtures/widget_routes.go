//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/domain"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"

	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	"github.com/gofiber/fiber/v3"
)

// ─── Request / Response DTOs ────────────────────────────────────────────────

type WidgetPartRequest struct {
	Label string `json:"label" example:"lens"`
	Slot  int    `json:"slot"  example:"0"`
	Tag   string `json:"tag"   example:"optical"`
}

type InsertWidgetRequest struct {
	Name     string              `json:"name"     example:"Widget One"`
	Material string              `json:"material" example:"aluminium"`
	Parts    []WidgetPartRequest `json:"parts,omitempty"`
}

func (r InsertWidgetRequest) ToCommand() *appqa.InsertWidgetCommand {
	parts := make([]appqa.WidgetPartInput, 0, len(r.Parts))
	for _, p := range r.Parts {
		parts = append(parts, appqa.WidgetPartInput{Label: p.Label, Slot: p.Slot, Tag: p.Tag})
	}
	return &appqa.InsertWidgetCommand{Name: r.Name, Material: r.Material, Parts: parts}
}

type InsertWidgetResponse struct {
	ID   domain.ID `json:"id"`
	Name string    `json:"name"`
}

func (InsertWidgetResponse) FromResult(r appqa.WidgetResult) InsertWidgetResponse {
	return InsertWidgetResponse{ID: r.ID, Name: r.Name}
}

// WidgetPartFilter is the nested (child) filter block. Its leaves reach the reader
// as the DOTTED paths WidgetParts.Label (child field) and WidgetParts.Tag
// (child-level sibling) — both unservable by the relational twin (→400), both
// row-selecting on the Mongo view.
type WidgetPartFilter struct {
	Label *string `query:"label" filter:"eq,icontains"`
	Tag   *string `query:"tag"   filter:"eq,icontains"`
}

// FindWidgetsRequest is the wire allowlist of the LIST reads. `name` is a
// root-own filter (served identically by both backings); `material` is the flat
// ROOT sibling; `widgetParts.*` are the child/child-sibling paths.
type FindWidgetsRequest struct {
	Name        *string          `query:"name"     filter:"eq,icontains"`
	Material    *string          `query:"material" filter:"eq,icontains"`
	WidgetParts WidgetPartFilter `query:"widgetParts"`

	First           *int64  `query:"first"`
	Last            *int64  `query:"last"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	OrderBy         *string `query:"orderBy"`
	Fields          *string `query:"fields"`
	OnlyTotal       *bool   `query:"onlyTotal"`
	IncludeArchived *bool   `query:"includeArchived"`
}

func (r FindWidgetsRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindWidgetsQuery {
	return &appqa.FindWidgetsQuery{Criteria: criteria}
}

type WidgetPartOutput struct {
	Label *string `json:"label,omitempty"`
	Slot  *int    `json:"slot,omitempty"`
	Tag   *string `json:"tag,omitempty"`
}

type FindWidgetsResponse struct {
	fwresponses.Auto
	ID          *string            `json:"id,omitempty"`
	Name        *string            `json:"name,omitempty"`
	Material    *string            `json:"material,omitempty"`
	WidgetParts []WidgetPartOutput `json:"widgetParts,omitempty"`
}

// FromResult is the wire mapping seat: the generic name-based Result→Response
// mapper. The by-id read serves the same shape (FindWidgetByIDResponse is an
// alias), so this one method feeds both routes and both backings.
func (FindWidgetsResponse) FromResult(r appqa.FindWidgetsResult) FindWidgetsResponse {
	return fwresponses.AutoFromResult[FindWidgetsResponse](r)
}

type FindWidgetByIDRequest struct {
	IncludeArchived *bool `query:"includeArchived"`
}

func (r FindWidgetByIDRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindWidgetByIDQuery {
	return &appqa.FindWidgetByIDQuery{Criteria: criteria}
}

type FindWidgetByIDResponse = FindWidgetsResponse

// ─── Routes ─────────────────────────────────────────────────────────────────

// MountWidgets registers the write + Mongo-served read routes:
//
//	POST /qa/widgets       insert (root + Material sibling + WidgetParts children)
//	GET  /qa/widgets       list (Mongo view — child/sibling filters row-select)
//	GET  /qa/widgets/:id   by id (Mongo view)
func MountWidgets(
	app *fiber.App,
	repo persistence.ScopedRepository[*qadomain.Widget],
	viewName string,
	d bootstrap.Deps,
) {
	g := app.Group("/qa/widgets")

	insertH, insertSpec := fwweb.CommandWithBodySpec(d.Pipeline,
		InsertWidgetRequest{},
		InsertWidgetResponse{}.FromResult,
		&handlers.InsertCommandHandler[*qadomain.Widget, *appqa.InsertWidgetCommand, appqa.WidgetResult]{
			Repo: repo,
		}, fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPost, "/",
		insertH, insertSpec,
		fwopenapi.Doc{
			Summary:     "Create a widget (root + Material sibling + child parts)",
			Description: "Creates a qa_widgets aggregate: the root, its 1:1 Material sibling (qa_widget_specs), and the native WidgetParts children (each with a Tag child-sibling).",
			Tags:        []string{"QA Widgets"},
		},
		fwopenapi.RequirePermission("gadgets:write"))

	listH, listSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindWidgetsRequest{},
		FindWidgetsResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindWidgetsQuery, appqa.FindWidgetsResult]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List widgets from the Mongo view",
			Description: "Root filter (`name`) plus the child/sibling filters (`material`, `widgetParts.label`, `widgetParts.tag`) row-select on the materialized document.",
			Tags:        []string{"QA Widgets"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	byIDH, byIDSpec := fwweb.QueryByIDSpec(d.Pipeline,
		FindWidgetByIDRequest{},
		FindWidgetByIDResponse{}.FromResult,
		&handlers.FindByIDQueryHandler[*appqa.FindWidgetByIDQuery, appqa.FindWidgetsResult]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:id",
		byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary: "Get a widget by id from the Mongo view",
			Tags:    []string{"QA Widgets"},
		},
		fwopenapi.RequirePermission("gadgets:read"))
}

// MountWidgetsRel registers the RelationalSource read twin:
//
//	GET /qa/rel/widgets      list (SoR — root `name` parity; child/sibling → 400)
//	GET /qa/rel/widgets/:id   by id (SoR)
func MountWidgetsRel(app *fiber.App, listView *query.ViewDefinition, d bootstrap.Deps) {
	g := app.Group("/qa/rel/widgets")

	listH, listSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindWidgetsRequest{},
		FindWidgetsResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindWidgetsQuery, appqa.FindWidgetsResult]{
			Reader: d.ViewReader, View: listView.Name(),
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List widgets from the relational SoR (RelationalSource mirror)",
			Description: "Root `name` filter/sort reach parity with the Mongo view; `material` (root sibling), `widgetParts.label` (child) and `widgetParts.tag` (child sibling) return 400 RelationalCapabilityNotification — a root SELECT cannot express them.",
			Tags:        []string{"QA Relational Views"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	byIDH, byIDSpec := fwweb.QueryByIDSpec(d.Pipeline,
		FindWidgetByIDRequest{},
		FindWidgetByIDResponse{}.FromResult,
		&handlers.FindByIDQueryHandler[*appqa.FindWidgetByIDQuery, appqa.FindWidgetsResult]{
			Reader: d.ViewReader, View: listView.Name(),
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:id",
		byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary: "Get a widget by id from the relational SoR",
			Tags:    []string{"QA Relational Views"},
		},
		fwopenapi.RequirePermission("gadgets:read"))
}
