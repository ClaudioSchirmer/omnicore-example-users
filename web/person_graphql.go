package web

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	fwgraphql "github.com/ClaudioSchirmer/omnicore/web/graphql"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
	"github.com/ClaudioSchirmer/omnicore-example-users/web/requests"
)

// MountPersonsGraphQL contributes the person view's read field to the
// service's single GraphQL registry — the GraphQL twin of MountPersons.
// Query-only, like the REST surface: a person is written through its roles.
// The `persons` connection reuses the same application handler and Request
// DTO the REST list mounts; the role sub-objects (`user`, `employee`) reflect
// into the schema from the Response DTO like any nested shape.
func MountPersonsGraphQL(
	reg *fwgraphql.Registry,
	view *query.ViewDefinition,
	d bootstrap.Deps,
) {
	reg.Register(fwgraphql.QueryWithParams[
		requests.FindPersonsByParamsRequest,
		requests.FindPersonsByParamsResponse,
	](
		"persons", "Person",
		&handlers.FindByParamsQueryHandler[*appqueries.FindPersonByParamsQuery]{
			Reader: d.ViewReader, View: view.Name(),
		},
		fwgraphql.RequirePermission("persons:read")))
}
