package web

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	fwgraphql "github.com/ClaudioSchirmer/omnicore/web/graphql"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/web/requests"
)

// MountEmployeesGraphQL contributes the Employee aggregate's fields to
// the service's single GraphQL registry — the GraphQL twin of
// MountEmployees, exactly parallel to MountUsersGraphQL. It reuses the
// SAME application handlers the REST surface mounts; each field carries the
// same Layer-1 permission as its REST twin. There is no by-id query — the
// `employees` connection's `where` filter covers the lookup, as on users.
func MountEmployeesGraphQL(
	reg *fwgraphql.Registry,
	repo persistence.ScopedRepository[*appdomain.Employee],
	svc domain.Service,
	view *query.ViewDefinition,
	d bootstrap.Deps,
) {
	reg.Register(fwgraphql.QueryWithParams[
		requests.FindEmployeesByParamsRequest,
		requests.FindEmployeesByParamsResponse,
	](
		"employees", "Employee",
		&handlers.FindByParamsQueryHandler[*appqueries.FindEmployeeByParamsQuery]{
			Reader: d.ViewReader, View: view.Name(),
		},
		fwgraphql.RequirePermission("employees:read")))

	reg.Register(fwgraphql.MutationWithBody[requests.InsertEmployeeRequest](
		"createEmployee", requests.InsertEmployeeResponse{}.FromResult,
		&handlers.SharedBaseInsertCommandHandler[*appdomain.Employee, *commands.InsertEmployeeCommand, commands.InsertEmployeeResult]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("employees:write")))

	reg.Register(fwgraphql.MutationWithBodyID[requests.UpdateEmployeeRequest](
		"updateEmployee", requests.UpdateEmployeeResponse{}.FromResult,
		&handlers.UpdateCommandHandler[*appdomain.Employee, *commands.UpdateEmployeeCommand, commands.UpdateEmployeeResult]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("employees:write")))

	reg.Register(fwgraphql.MutationWithBodyID[requests.PatchEmployeeRequest](
		"patchEmployee", requests.PatchEmployeeResponse{}.FromResult,
		&handlers.PartialUpdateCommandHandler[*appdomain.Employee, *commands.PatchEmployeeCommand, commands.PatchEmployeeResult]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("employees:write")))

	reg.Register(fwgraphql.MutationByID(
		"archiveEmployee",
		&handlers.ArchiveCommandHandler[*appdomain.Employee, *commands.ArchiveEmployeeCommand, fwresults.None]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("employees:archive")))

	reg.Register(fwgraphql.MutationByID(
		"unarchiveEmployee",
		&handlers.UnarchiveCommandHandler[*appdomain.Employee, *commands.UnarchiveEmployeeCommand, fwresults.None]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("employees:archive")))

	reg.Register(fwgraphql.MutationByID(
		"deleteEmployee",
		&handlers.DeleteCommandHandler[*appdomain.Employee, *commands.DeleteEmployeeCommand, fwresults.None]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("employees:delete")))
}
