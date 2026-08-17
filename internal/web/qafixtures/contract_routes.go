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

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"

	"github.com/gofiber/fiber/v3"
)

const contractTag = "QA Contracts (composite value objects)"

// MountContracts registers the write verbs plus the MONGO-projected read side.
func MountContracts(
	app *fiber.App,
	repo persistence.ScopedRepository[*qadomain.Contract],
	viewName string,
	d bootstrap.Deps,
) {
	g := app.Group("/qa/contracts")
	tags := []string{contractTag}

	insertH, insertSpec := fwweb.CommandWithBodySpec(d.Pipeline,
		InsertContractRequest{},
		ContractWriteResponse{}.FromResult,
		&handlers.InsertCommandHandler[*qadomain.Contract, *appqa.InsertContractCommand, appqa.ContractResult]{
			Repo: repo,
		}, fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPost, "/", insertH, insertSpec,
		fwopenapi.Doc{
			Summary:     "Create a contract",
			Description: "Two composite value objects land in five columns. Omitting `trialFrom` means the OPTIONAL composite is absent, which writes NULL to every one of its part columns.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:write"))

	updateH, updateSpec := fwweb.CommandWithBodyIDSpec(d.Pipeline,
		UpdateContractRequest{},
		ContractWriteResponse{}.FromResult,
		&handlers.UpdateCommandHandler[*qadomain.Contract, *appqa.UpdateContractCommand, appqa.ContractResult]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPut, "/:id", updateH, updateSpec,
		fwopenapi.Doc{
			Summary:     "Replace a contract",
			Description: "Changing one part produces an audit delta for THAT part alone; the unchanged part is absent from the event. Changing the currency trips a transition rule that reads the composite off the Old() ghost.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:write"))

	archiveH, archiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.ArchiveCommandHandler[*qadomain.Contract, *appqa.ArchiveContractCommand, fwresults.None]{Repo: repo},
		fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/archive", archiveH, archiveSpec,
		fwopenapi.Doc{Summary: "Archive a contract", Tags: tags},
		fwopenapi.RequirePermission("gadgets:archive"))

	unarchiveH, unarchiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.UnarchiveCommandHandler[*qadomain.Contract, *appqa.UnarchiveContractCommand, fwresults.None]{Repo: repo},
		fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/unarchive", unarchiveH, unarchiveSpec,
		fwopenapi.Doc{Summary: "Unarchive a contract", Tags: tags},
		fwopenapi.RequirePermission("gadgets:archive"))

	deleteH, deleteSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.DeleteCommandHandler[*qadomain.Contract, *appqa.DeleteContractCommand, fwresults.None]{Repo: repo},
		fiber.StatusNoContent)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodDelete, "/:id", deleteH, deleteSpec,
		fwopenapi.Doc{Summary: "Hard-delete a contract", Tags: tags},
		fwopenapi.RequirePermission("gadgets:write"))

	mountContractReads(g, viewName, d, tags,
		"Served from the Mongo projection, whose document stores the parts as flat physical columns.")
}

// MountContractsRel registers the SECOND read surface: the RelationalSource
// twin over the same root, served straight from the SoR. Same DTOs, same
// handlers — only the backing differs, so any divergence between the two is a
// decomposition bug rather than a surface bug.
func MountContractsRel(app *fiber.App, viewName string, d bootstrap.Deps) {
	g := app.Group("/qa/contracts-rel")
	mountContractReads(g, viewName, d, []string{contractTag},
		"Served straight from the relational SoR (read-your-writes, no CDC) — the read path that resolves every column through the scan plan.")
}

func mountContractReads(g fiber.Router, viewName string, d bootstrap.Deps, tags []string, backing string) {
	listH, listSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindContractsRequest{},
		FindContractsResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindContractsQuery, appqa.FindContractsResult]{Reader: d.ViewReader, View: viewName})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/", listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List contracts",
			Description: "Filter, sort and project by a PART of a composite (`?salaryAmount[gte]=`, `?orderBy=trialFrom`, `?fields=salaryAmount`) — a part is an ordinary logical field by the time the read side sees it. " + backing,
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:read"))

	byIDH, byIDSpec := fwweb.QueryByIDSpec(d.Pipeline,
		FindContractByIDRequest{},
		FindContractsResponse{}.FromResult,
		&handlers.FindByIDQueryHandler[*appqa.FindContractByIDQuery, appqa.FindContractsResult]{Reader: d.ViewReader, View: viewName})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:id", byIDH, byIDSpec,
		fwopenapi.Doc{Summary: "Get a contract by id", Description: backing, Tags: tags},
		fwopenapi.RequirePermission("gadgets:read"))
}
