//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
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

// MountGadgetNotes registers the GadgetNote's own surface under
// /qa/gadget-notes: create + archive/unarchive (to exercise the composed
// leg's archived gate) + the leg view's direct list. The list shows EVERY
// note — including kind=internal — which is what makes the composed by-id
// overlay (R9) observable by contrast.
func MountGadgetNotes(
	app *fiber.App,
	repo persistence.ScopedRepository[*qadomain.GadgetNote],
	viewName string,
	d bootstrap.Deps,
) {
	g := app.Group("/qa/gadget-notes")

	insertH, insertSpec := fwweb.HandleCommandWithBodySpec(d.Pipeline,
		InsertGadgetNoteRequest{},
		InsertGadgetNoteResponse{}.FromResult,
		&handlers.InsertCommandHandler[*qadomain.GadgetNote, *appqa.InsertGadgetNoteCommand, appqa.InsertGadgetNoteResult]{
			Repo: repo,
		}, fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPost, "/",
		insertH, insertSpec,
		fwopenapi.Doc{
			Summary:     "Attach a note to a gadget",
			Description: "Creates a gadget note (plain FK to gadgets.id — the two aggregates share no write-side declaration). `kind` is `public` or `internal`.",
			Tags:        []string{"QA Gadget Notes"},
		},
		fwopenapi.RequirePermission("gadgets:write"))

	listH, listSpec := fwweb.HandleQueryWithParamsSpec(d.Pipeline,
		FindGadgetNotesRequest{},
		fwresponses.AutoFromDoc[FindGadgetNotesResponse],
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetNotesQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List gadget notes (the composed leg's own view)",
			Description: "Direct paged read of the `gadget_notes` view — the same view the `gadgets_full` composition links as its 1:N leg. Shows every note (public AND internal): per-leg overlays apply to the composed surface, not here. Also the road to the full set when a composed segment truncates at its per-parent ceiling.",
			Tags:        []string{"QA Gadget Notes"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	archiveH, archiveSpec := fwweb.HandleCommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.ArchiveCommandHandler[*qadomain.GadgetNote, *appqa.ArchiveGadgetNoteCommand, fwresults.None]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/archive",
		archiveH, archiveSpec,
		fwopenapi.Doc{
			Summary:     "Archive (soft-delete) a gadget note",
			Description: "Soft-deletes the note: it vanishes from the composed `notes` segment on default reads (the leg's own gate) and from this view's default list; `?includeArchived=true` surfaces it on both.",
			Tags:        []string{"QA Gadget Notes"},
		},
		fwopenapi.RequirePermission("gadgets:archive"))

	unarchiveH, unarchiveSpec := fwweb.HandleCommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.UnarchiveCommandHandler[*qadomain.GadgetNote, *appqa.UnarchiveGadgetNoteCommand, fwresults.None]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/unarchive",
		unarchiveH, unarchiveSpec,
		fwopenapi.Doc{
			Summary:     "Unarchive a gadget note",
			Description: "Restores a soft-deleted note (and its composed-segment visibility).",
			Tags:        []string{"QA Gadget Notes"},
		},
		fwopenapi.RequirePermission("gadgets:archive"))
}

// MountGadgetsFull registers the COMPOSED read surface under /qa/gadgets-full.
// Note what is absent: no repository, no collection, no SyncEngine wiring —
// the composed name ("gadgets_full") goes exactly where a view name goes, on
// the same handlers, and the framework's ComposedViewReader orchestrates the
// read-time join (primary page + one batch fetch per leg).
func MountGadgetsFull(
	app *fiber.App,
	composed *query.ComposedViewDefinition,
	d bootstrap.Deps,
) {
	g := app.Group("/qa/gadgets-full")

	listH, listSpec := fwweb.HandleQueryWithParamsSpec(d.Pipeline,
		FindGadgetsFullRequest{},
		fwresponses.AutoFromDoc[FindGadgetsFullResponse],
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsFullQuery]{
			Reader: d.ViewReader, View: composed.Name(),
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List gadgets with mirror + notes (read-time composition)",
			Description: "Paged read against the `gadgets_full` ComposedView — never materialized, never synced: the `gadgets` view drives rows/sort/pagination/total/cursors; `upstreamMirror` (1:1 external, null when absent) and `notes` (1:N internal, first 3 by text, empty when absent) are fetched by key at read time. Root filters select rows; `?notes.text=` / `?notes.kind=` filter the segment content only; `?sort=notes.*` is rejected with 400; `?includeArchived=true` lifts every leg's gate (the mirror has none — no-op).",
			Tags:        []string{"QA Gadgets Full"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	byIDH, byIDSpec := fwweb.HandleQueryByIDSpec(d.Pipeline,
		FindGadgetFullByIDRequest{},
		fwresponses.AutoFromDoc[FindGadgetFullByIDResponse],
		&handlers.FindByIDQueryHandler[*appqa.FindGadgetFullByIDQuery]{
			Reader: d.ViewReader, View: composed.Name(),
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:id",
		byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary:     "Get a gadget with mirror + notes by id (read-time composition)",
			Description: "Composed by-id read: one primary fetch + one keyed batch per leg. Carries the per-leg authorization showcase (R9): the query's ToCriteria overlays `Notes.Kind=public`, so internal notes never surface here while staying visible on GET /qa/gadget-notes. 404 when the gadget is absent or filtered out.",
			Tags:        []string{"QA Gadgets Full"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	// CSV export over the composed name — same Request DTO, same handler; the
	// ComposedViewDefinition satisfies the ExportView surface (its plan is the
	// primary's tree + one branch per leg).
	csvH, csvSpec := fwweb.HandleQueryAsCSVSpec(d.Pipeline,
		FindGadgetsFullRequest{},
		composed,
		d.Export,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsFullQuery]{
			Reader: d.ViewReader, View: composed.Name(),
		},
		export.WithDelimiter(','))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/gadgets-full.csv",
		csvH, csvSpec,
		fwopenapi.Doc{
			Summary:     "Export gadgets-full as CSV (composed export)",
			Description: "Streams the composed read as a hierarchical CSV: gadget columns at the root level, `upstreamMirror` and `notes` as nested levels — the same plan shape an Embed produces, built at read time. `?fields=` narrows columns into the segments.",
			Tags:        []string{"QA Gadgets Full"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	// XLSX export — identical surface, different encoder (format-neutral core
	// reused verbatim, exactly like the canonical /users.xlsx twin).
	xlsxH, xlsxSpec := fwweb.HandleQueryAsXLSXSpec(d.Pipeline,
		FindGadgetsFullRequest{},
		composed,
		d.Export,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsFullQuery]{
			Reader: d.ViewReader, View: composed.Name(),
		},
		export.WithSheetName("GadgetsFull"))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/gadgets-full.xlsx",
		xlsxH, xlsxSpec,
		fwopenapi.Doc{
			Summary:     "Export gadgets-full as XLSX (composed export)",
			Description: "Same composed export surface as /qa/gadgets-full.csv, rendered by the XLSX encoder — leg branches as nested column levels.",
			Tags:        []string{"QA Gadgets Full"},
		},
		fwopenapi.RequirePermission("gadgets:read"))
}
