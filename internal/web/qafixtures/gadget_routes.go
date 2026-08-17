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

// MountGadgets registers the QA-only Gadget routes under /qa/gadgets:
//
//	POST   /qa/gadgets         Auto insert   (command AfterBegin/BeforeCommit hooks)
//	POST   /qa/gadgets/custom  manual insert (WithAfterBegin/WithBeforeCommit closures)
//	GET    /qa/gadgets         list (full filter-operator vocabulary)
//	GET    /qa/gadgets/:id     by id
//	DELETE /qa/gadgets/:id     hard delete
//
// The Auto and manual insert routes share the same Request DTO and command; the
// only difference is which path invokes the hooks — proving hook invariance.
// Both roll back when Code == "POISON".
func MountGadgets(
	app *fiber.App,
	repo persistence.ScopedRepository[*qadomain.Gadget],
	journal appqa.GadgetJournal,
	publisher appqa.GadgetEventPublisher,
	view *query.ViewDefinition,
	d bootstrap.Deps,
) {
	viewName := view.Name()
	g := app.Group("/qa/gadgets")

	// Auto insert — the framework detects the command's AfterBegin/BeforeCommit
	// provider methods and fires them inside the write TX.
	insertH, insertSpec := fwweb.CommandWithBodySpec(d.Pipeline,
		InsertGadgetRequest{},
		InsertGadgetResponse{}.FromResult,
		&handlers.InsertCommandHandler[*qadomain.Gadget, *appqa.InsertGadgetCommand, appqa.InsertGadgetResult]{
			Repo: repo,
		}, fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPost, "/",
		insertH, insertSpec,
		fwopenapi.Doc{
			Summary:     "Create a gadget (Auto path, in-TX lifecycle hooks)",
			Description: "Creates a gadget via the Auto InsertCommandHandler. The command declares AfterBegin (slot A — journals `before-write` with no id) and BeforeCommit (slot D — journals `after-write` with the generated id). Sending `code:\"POISON\"` makes BeforeCommit return an error, rolling back the whole TX so the gadget row AND both journal rows vanish.",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:write"))

	// Manual insert — same lifecycle by hand, hooks attached as closures via
	// WithAfterBegin/WithBeforeCommit on repo.Scope.
	customH, customSpec := fwweb.CommandWithBodySpec(d.Pipeline,
		InsertGadgetRequest{},
		InsertGadgetResponse{}.FromResult,
		&appqa.InsertGadgetCustomHandler{Repo: repo, Journal: journal, Publisher: publisher},
		fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPost, "/custom",
		customH, customSpec,
		fwopenapi.Doc{
			Summary:     "Create a gadget (manual path, closure lifecycle hooks)",
			Description: "Identical behavior to POST /qa/gadgets, but the handler is hand-rolled and attaches the two hooks as WithAfterBegin/WithBeforeCommit closures on repo.Scope — proving hook invariance across the Auto and manual paths. Same `code:\"POISON\"` forced-rollback case.",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:write"))

	// List — the full filter-operator vocabulary.
	listH, listSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindGadgetsRequest{},
		FindGadgetsResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery, appqa.FindGadgetsResult]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List gadgets (paged + full filter vocabulary)",
			Description: "Paged read against the `gadgets` Mongo view. The four fields spread all 16 filter operators across their leaves (eq,ne,in,nin,gte,lte,gt,lt,startswith,contains,ieq,ine,iin,inin,istartswith,icontains). Unknown keys/operators return 400.",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	// Computed-field showcase — `label` carries no column: the Query's
	// FromQueryResult derives it from Code+Name, and the Response declares
	// `computed:"Code,Name"` so the framework pushes those two to the store in
	// its place. Name is deliberately absent from that Response, proving a
	// source need not reach the wire. Mounted BEFORE /:id so the literal
	// segment wins the match.
	computedH, computedSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindGadgetsRequest{},
		FindGadgetsComputedResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery, appqa.FindGadgetsResult]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/computed",
		computedH, computedSpec,
		fwopenapi.Doc{
			Summary:     "List gadgets with a COMPUTED field (label)",
			Description: "Same `gadgets` view and handler as GET /qa/gadgets, projected through a Response whose `label` is computed by FromQueryResult from code+name. `?fields=label` reads the two sources and answers with label alone; `?orderBy=label` is 400 ComputedFieldNotSortableNotification (ordering happens in the store and the keyset cursor is built from stored values).",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	// CSV twin of the computed list — the export derives its columns from the
	// SAME Response, so `label` is a real column and `?fields=label` keeps it
	// (its sources go to the store, never to the column set).
	computedCSVH, computedCSVSpec := fwweb.QueryAsCSVSpec(d.Pipeline,
		FindGadgetsRequest{},
		FindGadgetsComputedResponse{}.FromResult,
		view,
		d.Export,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery, appqa.FindGadgetsResult]{
			Reader: d.ViewReader, View: viewName,
		},
		export.WithDelimiter(','))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/gadgets-computed.csv",
		computedCSVH, computedCSVSpec,
		fwopenapi.Doc{
			Summary:     "Export the computed gadget list as CSV",
			Description: "Tabular twin of GET /qa/gadgets/computed. The `label` column is derived per row by FromQueryResult; its header comes from the Response's exportLabelKey rendered in the request language.",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	// Bare list — the reserved-gate proof surface: same view, same handler,
	// but the Request DTO declares NO reserved control keys, so every
	// control (?first/?last/?after/?before/?orderBy/?fields/?search/
	// ?includeArchived/?onlyTotal) must reject 400 through the canonical
	// gateway while the two filter leaves keep working. Mounted BEFORE the
	// /:id route so the literal segment wins the match.
	bareH, bareSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindGadgetsBareRequest{},
		FindGadgetsResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery, appqa.FindGadgetsResult]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/bare",
		bareH, bareSpec,
		fwopenapi.Doc{
			Summary:     "List gadgets (bare DTO — no reserved controls declared)",
			Description: "The reserved-gate proof: this endpoint's Request DTO declares only the `code`/`name` filter leaves. Every reserved control key on the wire rejects 400 (the DTO governs what an endpoint exposes); filters work normally.",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	// Bare by-id — the by-id half of the reserved-gate proof: the DTO declares
	// nothing, so ?includeArchived (the by-id surface's one reserved control)
	// rejects 400 through the same DTO gate.
	bareByIDH, bareByIDSpec := fwweb.QueryByIDSpec(d.Pipeline,
		FindGadgetBareByIDRequest{},
		FindGadgetByIDResponse{}.FromResult,
		&handlers.FindByIDQueryHandler[*appqa.FindGadgetByIDQuery, appqa.FindGadgetByIDResult]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/bare/:id",
		bareByIDH, bareByIDSpec,
		fwopenapi.Doc{
			Summary:     "Get a gadget by id (bare DTO — no reserved controls declared)",
			Description: "The by-id reserved-gate proof: `?includeArchived` rejects 400 because this endpoint's Request DTO does not declare it.",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	// By id.
	byIDH, byIDSpec := fwweb.QueryByIDSpec(d.Pipeline,
		FindGadgetByIDRequest{},
		FindGadgetByIDResponse{}.FromResult,
		&handlers.FindByIDQueryHandler[*appqa.FindGadgetByIDQuery, appqa.FindGadgetByIDResult]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:id",
		byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary:     "Get a gadget by id",
			Description: "Fetches the gadget document from the `gadgets` Mongo view. Only `?includeArchived=true` is recognized. 404 when absent or filtered out.",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	// Delete — hard delete via the Auto DeleteCommandHandler.
	deleteH, deleteSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.DeleteCommandHandler[*qadomain.Gadget, *appqa.DeleteGadgetCommand, fwresults.None]{
			Repo: repo,
		}, fiber.StatusNoContent)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodDelete, "/:id",
		deleteH, deleteSpec,
		fwopenapi.Doc{
			Summary:     "Hard-delete a gadget",
			Description: "Irreversible hard delete of the gadget row.",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:delete"))

	// Archive / Unarchive — the DeletedAt pair, so the DeleteOnArchive view
	// (gadgets_hot) can be exercised: archive drops the doc there but keeps it
	// (hidden) in the default gadgets view.
	archiveH, archiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.ArchiveCommandHandler[*qadomain.Gadget, *appqa.ArchiveGadgetCommand, fwresults.None]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/archive",
		archiveH, archiveSpec,
		fwopenapi.Doc{
			Summary:     "Archive (DeletedAt) a gadget",
			Description: "DeletedAts the gadget: kept (hidden) in the default gadgets view, DROPPED from the DeleteOnArchive gadgets_hot view.",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:archive"))

	unarchiveH, unarchiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.UnarchiveCommandHandler[*qadomain.Gadget, *appqa.UnarchiveGadgetCommand, fwresults.None]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/unarchive",
		unarchiveH, unarchiveSpec,
		fwopenapi.Doc{
			Summary:     "Unarchive a gadget",
			Description: "Restores a archived gadget.",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:archive"))
}
