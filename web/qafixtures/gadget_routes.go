//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/application/qafixtures"
	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/domain/qafixtures"

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
	viewName string,
	d bootstrap.Deps,
) {
	g := app.Group("/qa/gadgets")

	// Auto insert — the framework detects the command's AfterBegin/BeforeCommit
	// provider methods and fires them inside the write TX.
	insertH, insertSpec := fwweb.HandleCommandWithBodySpec(d.Pipeline,
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
	customH, customSpec := fwweb.HandleCommandWithBodySpec(d.Pipeline,
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
	listH, listSpec := fwweb.HandleQueryWithParamsSpec(d.Pipeline,
		FindGadgetsRequest{},
		fwresponses.AutoFromDoc[FindGadgetsResponse],
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery]{
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

	// By id.
	byIDH, byIDSpec := fwweb.HandleQueryByIDSpec(d.Pipeline,
		FindGadgetByIDRequest{},
		fwresponses.AutoFromDoc[FindGadgetByIDResponse],
		&handlers.FindByIDQueryHandler[*appqa.FindGadgetByIDQuery]{
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
	deleteH, deleteSpec := fwweb.HandleCommandByIDSpec(d.Pipeline,
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

	// Archive / Unarchive — the soft-delete pair, so the DeleteOnArchive view
	// (gadgets_hot) can be exercised: archive drops the doc there but keeps it
	// (hidden) in the default gadgets view.
	archiveH, archiveSpec := fwweb.HandleCommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.ArchiveCommandHandler[*qadomain.Gadget, *appqa.ArchiveGadgetCommand, fwresults.None]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/archive",
		archiveH, archiveSpec,
		fwopenapi.Doc{
			Summary:     "Archive (soft-delete) a gadget",
			Description: "Soft-deletes the gadget: kept (hidden) in the default gadgets view, DROPPED from the DeleteOnArchive gadgets_hot view.",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:archive"))

	unarchiveH, unarchiveSpec := fwweb.HandleCommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.UnarchiveCommandHandler[*qadomain.Gadget, *appqa.UnarchiveGadgetCommand, fwresults.None]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/unarchive",
		unarchiveH, unarchiveSpec,
		fwopenapi.Doc{
			Summary:     "Unarchive a gadget",
			Description: "Restores a soft-deleted gadget.",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:archive"))
}
