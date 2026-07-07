package main

import (
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	fwgraphql "github.com/ClaudioSchirmer/omnicore/web/graphql"

	appinfra "github.com/ClaudioSchirmer/omnicore-example-users/internal/infra"
	appweb "github.com/ClaudioSchirmer/omnicore-example-users/internal/web"

	"github.com/gofiber/fiber/v3"
)

// PersonsFeature bundles the all-in-one person view (the SharedBaseView over
// the shared Person identity) and mounts the READ-ONLY /persons/* routes. It
// owns no repository and no commands — a person is written through its roles
// (UsersFeature / EmployeesFeature); this feature only contributes the
// composed projection and its read surface.
type PersonsFeature struct {
	view *query.ViewDefinition
}

// NewPersonsFeature builds the feature's singleton view exactly once.
// PersonView() is called here — its single call site.
func NewPersonsFeature(_ bootstrap.Deps) *PersonsFeature {
	return &PersonsFeature{view: appinfra.PersonView()}
}

// Views satisfies bootstrap.ReadableFeature — contributes the persons view to
// the SyncEngine (which also subscribes to both role tables' topics for it).
func (f *PersonsFeature) Views() []*query.ViewDefinition {
	return []*query.ViewDefinition{f.view}
}

// Mount satisfies bootstrap.Feature — delegates HTTP registration to web/.
func (f *PersonsFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	appweb.MountPersons(app, f.view, d)
}

// MountGraphQL contributes the persons connection to the service's single
// GraphQL registry — the GraphQL twin of Mount.
func (f *PersonsFeature) MountGraphQL(reg *fwgraphql.Registry, d bootstrap.Deps) {
	appweb.MountPersonsGraphQL(reg, f.view, d)
}
