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

// MountGadgetKits registers the EmbedInChild-over-upstream_gadgets showcase:
// create a kit with native child lines (each referencing a gadget id) and read
// the composed qa_gadget_kits_view where each line is enriched 1:1 with its
// upstream gadget mirror. Gated on the upstream_gadgets subscription by the
// feature wiring (same as gadgets_embedded).
func MountGadgetKits(
	app *fiber.App,
	repo persistence.ScopedRepository[*qadomain.GadgetKit],
	viewName string,
	view *query.ViewDefinition,
	d bootstrap.Deps,
) {
	g := app.Group("/qa/gadget-kits")

	insertH, insertSpec := fwweb.CommandWithBodySpec(d.Pipeline,
		InsertGadgetKitRequest{},
		InsertGadgetKitResponse{}.FromResult,
		&handlers.InsertCommandHandler[*qadomain.GadgetKit, *appqa.InsertGadgetKitCommand, appqa.GadgetKitResult]{Repo: repo},
		fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPost, "/",
		insertH, insertSpec,
		fwopenapi.Doc{
			Summary:     "Create a gadget kit (EmbedInChild over upstream_gadgets)",
			Description: "Creates a qa_gadget_kits row with native child lines; each line's `gadgetId` is enriched 1:1 with its upstream gadget mirror via EmbedInChild.",
			Tags:        []string{"QA Gadget Kits (EmbedInChild)"},
		},
		fwopenapi.RequirePermission("gadgets:write"))

	byIDH, byIDSpec := fwweb.QueryByIDSpec(d.Pipeline,
		FindGadgetKitByIDRequest{},
		FindGadgetKitByIDResponse{}.FromResult,
		&handlers.FindByIDQueryHandler[*appqa.FindGadgetKitByIDQuery, appqa.FindGadgetKitByIDResult]{Reader: d.ViewReader, View: viewName})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:id",
		byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary:     "Get a gadget kit by id (enriched child lines)",
			Description: "Reads qa_gadget_kits_view: the kit plus its `gadgetKitLines` array, each line carrying `gadget` — the EmbedInChild enrichment (the upstream gadget the line references).",
			Tags:        []string{"QA Gadget Kits (EmbedInChild)"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	listH, listSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindGadgetKitsRequest{},
		FindGadgetKitsListResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetKitsQuery, appqa.FindGadgetKitsResult]{Reader: d.ViewReader, View: viewName})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List gadget kits (filter/sort/fields into the enriched child)",
			Description: "Paged read of qa_gadget_kits_view; root filter (`name`) and the nested enriched-child filter (`gadgetKitLines.gadget.name`) select rows.",
			Tags:        []string{"QA Gadget Kits (EmbedInChild)"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	csvH, csvSpec := fwweb.QueryAsCSVSpec(d.Pipeline,
		FindGadgetKitsRequest{},
		FindGadgetKitsListResponse{}.FromResult,
		view, d.Export,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetKitsQuery, appqa.FindGadgetKitsResult]{Reader: d.ViewReader, View: viewName},
		export.WithDelimiter(','))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/gadget-kits.csv",
		csvH, csvSpec,
		fwopenapi.Doc{Summary: "Export gadget kits as CSV (walks the enriched child branch)", Tags: []string{"QA Gadget Kits (EmbedInChild)"}},
		fwopenapi.RequirePermission("gadgets:read"))
}

// ─── Create DTOs ─────────────────────────────────────────────────────────────

type InsertGadgetKitRequest struct {
	Name  string                 `json:"name" example:"Starter Kit"`
	Lines []GadgetKitLineRequest `json:"lines,omitempty"`
}

// GadgetKitLineRequest is one native child line: `gadgetId` (the enriched ParentID) + `note`.
type GadgetKitLineRequest struct {
	GadgetID *string `json:"gadgetId,omitempty"`
	Note     string  `json:"note"`
}

func (r InsertGadgetKitRequest) ToCommand() *appqa.InsertGadgetKitCommand {
	lines := make([]appqa.GadgetKitLineInput, 0, len(r.Lines))
	for _, l := range r.Lines {
		lines = append(lines, appqa.GadgetKitLineInput{GadgetID: l.GadgetID, Note: l.Note})
	}
	return &appqa.InsertGadgetKitCommand{Name: r.Name, Lines: lines}
}

type InsertGadgetKitResponse struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func (InsertGadgetKitResponse) FromResult(r appqa.GadgetKitResult) InsertGadgetKitResponse {
	return InsertGadgetKitResponse{ID: r.ID.String(), Name: r.Name}
}

// ─── Read DTOs ───────────────────────────────────────────────────────────────

type FindGadgetKitByIDRequest struct {
	IncludeArchived *bool `query:"includeArchived"`
}

func (r FindGadgetKitByIDRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindGadgetKitByIDQuery {
	return &appqa.FindGadgetKitByIDQuery{Criteria: criteria}
}

// GadgetMirrorOutput is one embedded upstream_gadgets document (the enrichment).
// Field names match the GadgetUpstreamMirrorSchema Go names (ID/Code/Name).
type GadgetMirrorOutput struct {
	ID   *string `json:"id,omitempty"`
	Code *string `json:"code,omitempty"`
	Name *string `json:"name,omitempty"`
}

// GadgetKitLineOutput is one enriched native child line. `Gadget` (Go segment
// "Gadget", doc field "gadget") is the EmbedInChild sub-document.
type GadgetKitLineOutput struct {
	GadgetID *string             `json:"gadgetId,omitempty"`
	Note     *string             `json:"note,omitempty"`
	Gadget   *GadgetMirrorOutput `json:"gadget,omitempty"`
}

// FindGadgetKitByIDResponse — Go field GadgetKitLines matches the derived child
// segment, which is the mapping handle from the Result.
type FindGadgetKitByIDResponse struct {
	fwresponses.Auto
	ID             string                `json:"id"`
	Name           string                `json:"name"`
	GadgetKitLines []GadgetKitLineOutput `json:"gadgetKitLines,omitempty"`
}

func (FindGadgetKitByIDResponse) FromResult(r appqa.FindGadgetKitByIDResult) FindGadgetKitByIDResponse {
	return fwresponses.AutoFromResult[FindGadgetKitByIDResponse](r)
}

// ─── List DTOs ───────────────────────────────────────────────────────────────

// GadgetMirrorFilter filters the enriched gadget sub-doc.
type GadgetMirrorFilter struct {
	Code *string `query:"code" filter:"eq,icontains"`
	Name *string `query:"name" filter:"eq,icontains"`
}

// GadgetKitLineFilter is the nested filter group: the line's own `note` plus,
// one level deeper, the EmbedInChild enrichment (gadgetKitLines.gadget.name).
type GadgetKitLineFilter struct {
	Note   *string            `query:"note" filter:"eq,icontains"`
	Gadget GadgetMirrorFilter `query:"gadget"`
}

type FindGadgetKitsRequest struct {
	Name *string `query:"name" filter:"eq,icontains" sort:"asc,desc"`

	GadgetKitLines GadgetKitLineFilter `query:"gadgetKitLines"`

	First           *int64  `query:"first"`
	Last            *int64  `query:"last"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	Fields          *string `query:"fields"`
	OnlyTotal       *bool   `query:"onlyTotal"`
	IncludeArchived *bool   `query:"includeArchived"`
	OrderBy         *string `query:"orderBy"`
}

func (r FindGadgetKitsRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindGadgetKitsQuery {
	return &appqa.FindGadgetKitsQuery{Criteria: criteria}
}

type FindGadgetKitsListResponse struct {
	fwresponses.Auto
	ID             *string               `json:"id,omitempty"`
	Name           *string               `json:"name,omitempty"`
	GadgetKitLines []GadgetKitLineOutput `json:"gadgetKitLines,omitempty"`
}

// FromResult is the wire mapping seat of the paged list and of the CSV export
// (which now derives its columns from this DTO).
func (FindGadgetKitsListResponse) FromResult(r appqa.FindGadgetKitsResult) FindGadgetKitsListResponse {
	return fwresponses.AutoFromResult[FindGadgetKitsListResponse](r)
}
