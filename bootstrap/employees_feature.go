package main

import (
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	fwgraphql "github.com/ClaudioSchirmer/omnicore/web/graphql"

	appinfra "github.com/ClaudioSchirmer/omnicore-example-users/internal/infra"
	appviews "github.com/ClaudioSchirmer/omnicore-example-users/internal/infra/views"
	appweb "github.com/ClaudioSchirmer/omnicore-example-users/internal/web"

	"github.com/gofiber/fiber/v3"
)

// EmployeesFeature bundles the Employee aggregate's repo + view and
// mounts the /employees/* routes — the second role over the shared Person
// identity, structurally identical to UsersFeature. Like User, Employee
// needs no domain service (identity uniqueness comes from the SharedBase
// deterministic id + the role's shared PK), so the handlers receive nil.
type EmployeesFeature struct {
	repo *appinfra.EmployeeRepository
	view *query.ViewDefinition
}

// NewEmployeesFeature builds the feature's singletons exactly once.
// EmployeeView() is called here — its single call site.
func NewEmployeesFeature(d bootstrap.Deps) *EmployeesFeature {
	return &EmployeesFeature{
		repo: appinfra.NewEmployeeRepository(d.DB),
		view: appviews.EmployeeView(),
	}
}

// Views satisfies bootstrap.ReadableFeature.
func (f *EmployeesFeature) Views() []*query.ViewDefinition {
	return []*query.ViewDefinition{f.view}
}

// Mount satisfies bootstrap.Feature — delegates HTTP registration to web/.
func (f *EmployeesFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	appweb.MountEmployees(app, f.repo, nil, f.view, d)
}

// MountGraphQL contributes the Employee fields to the service's single
// GraphQL registry — the GraphQL twin of Mount.
func (f *EmployeesFeature) MountGraphQL(reg *fwgraphql.Registry, d bootstrap.Deps) {
	appweb.MountEmployeesGraphQL(reg, f.repo, nil, f.view, d)
}
