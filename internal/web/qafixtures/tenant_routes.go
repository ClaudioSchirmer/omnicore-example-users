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

const tenantTag = "QA Tenants (old state + archive as an update)"

// MountTenants registers all five state-changing verbs plus the Mongo-projected
// read side. Every route is an Auto handler — the suite's whole point is that
// these guarantees hold on the path a service gets for free.
func MountTenants(
	app *fiber.App,
	repo persistence.ScopedRepository[*qadomain.Tenant],
	viewName string,
	d bootstrap.Deps,
) {
	g := app.Group("/qa/tenants")
	tags := []string{tenantTag}

	insertH, insertSpec := fwweb.CommandWithBodySpec(d.Pipeline,
		InsertTenantRequest{},
		TenantWriteResponse{}.FromResult,
		&handlers.InsertCommandHandler[*qadomain.Tenant, *appqa.InsertTenantCommand, appqa.TenantResult]{
			Repo: repo,
		}, fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPost, "/", insertH, insertSpec,
		fwopenapi.Doc{Summary: "Create a tenant with seats", Tags: tags},
		fwopenapi.RequirePermission("gadgets:write"))

	updateH, updateSpec := fwweb.CommandWithBodyIDSpec(d.Pipeline,
		UpdateTenantRequest{},
		TenantWriteResponse{}.FromResult,
		&handlers.UpdateCommandHandler[*qadomain.Tenant, *appqa.UpdateTenantCommand, appqa.TenantResult]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPut, "/:id", updateH, updateSpec,
		fwopenapi.Doc{
			Summary:     "Replace a tenant",
			Description: "Sending status=closing makes the domain finish the write as an archive (CompleteAsArchive) — same request, archive semantics.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:write"))

	archiveH, archiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.ArchiveCommandHandler[*qadomain.Tenant, *appqa.ArchiveTenantCommand, fwresults.None]{Repo: repo},
		fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/archive", archiveH, archiveSpec,
		fwopenapi.Doc{Summary: "Archive a tenant", Tags: tags},
		fwopenapi.RequirePermission("gadgets:archive"))

	unarchiveH, unarchiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.UnarchiveCommandHandler[*qadomain.Tenant, *appqa.UnarchiveTenantCommand, fwresults.None]{Repo: repo},
		fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/unarchive", unarchiveH, unarchiveSpec,
		fwopenapi.Doc{Summary: "Unarchive a tenant", Tags: tags},
		fwopenapi.RequirePermission("gadgets:archive"))

	deleteH, deleteSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.DeleteCommandHandler[*qadomain.Tenant, *appqa.DeleteTenantCommand, fwresults.None]{Repo: repo},
		fiber.StatusNoContent)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodDelete, "/:id", deleteH, deleteSpec,
		fwopenapi.Doc{Summary: "Hard-delete a tenant", Tags: tags},
		fwopenapi.RequirePermission("gadgets:write"))

	listH, listSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindTenantsRequest{},
		FindTenantsResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindTenantsQuery, appqa.FindTenantsResult]{Reader: d.ViewReader, View: viewName})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/", listH, listSpec,
		fwopenapi.Doc{Summary: "List tenants", Tags: tags},
		fwopenapi.RequirePermission("gadgets:read"))

	byIDH, byIDSpec := fwweb.QueryByIDSpec(d.Pipeline,
		FindTenantByIDRequest{},
		FindTenantsResponse{}.FromResult,
		&handlers.FindByIDQueryHandler[*appqa.FindTenantByIDQuery, appqa.FindTenantsResult]{Reader: d.ViewReader, View: viewName})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:id", byIDH, byIDSpec,
		fwopenapi.Doc{Summary: "Get a tenant by id", Tags: tags},
		fwopenapi.RequirePermission("gadgets:read"))
}
