package web

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	fwgrpc "github.com/ClaudioSchirmer/omnicore/web/grpc"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
	"github.com/ClaudioSchirmer/omnicore-example-users/proto/gen/usersv1"
	"github.com/ClaudioSchirmer/omnicore-example-users/proto/gen/usersv1/usersv1connect"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/web/requests"
)

// MountUsersGRPC registers the User aggregate's RPCs into the service's
// single gRPC registry — the gRPC twin of MountUsers (REST) and
// MountUsersGraphQL: one declarative Register per RPC, wire bindings
// co-located in web/requests (user_grpc_bindings.go), and the SAME
// application handlers every other surface dispatches to. Each procedure
// carries the same Layer-1 permission as its REST/GraphQL twin (enforced
// under auth.authorization.enabled, inert otherwise).
func MountUsersGRPC(
	reg *fwgrpc.Registry,
	repo persistence.ScopedRepository[*appdomain.User],
	view *query.ViewDefinition,
	d bootstrap.Deps,
) {
	reg.Register(fwgrpc.CommandWithBody(usersv1connect.UsersServiceCreateUserProcedure,
		requests.CreateUserPB{}.ToCommand,
		requests.CreateUserPB{}.FromResult,
		&handlers.SharedBaseInsertCommandHandler[*appdomain.User, *commands.InsertUserCommand, commands.InsertUserResult]{
			Repo: repo,
		},
		fwgrpc.RequirePermission("users:write")))

	// WithBodyID: id + full body, strict (the PUT sibling — the handler
	// embeds FullBody; the Strict set mirrors the REST contract).
	reg.Register(fwgrpc.CommandWithBodyID(usersv1connect.UsersServiceUpdateUserProcedure,
		(*usersv1.UpdateUserRequest).GetId,
		requests.UpdateUserPB{}.ToCommand,
		requests.UpdateUserPB{}.FromResult,
		&handlers.UpdateCommandHandler[*appdomain.User, *commands.UpdateUserCommand, commands.UpdateUserResult]{
			Repo: repo,
		},
		fwgrpc.Strict("id", "name", "email", "user_name"),
		fwgrpc.RequirePermission("users:write")))

	reg.Register(fwgrpc.QueryWithParams(usersv1connect.UsersServiceListUsersProcedure,
		requests.ListUsersPB{}.ToQuery,
		requests.ListUsersPB{}.FromPage,
		&handlers.FindByParamsQueryHandler[*appqueries.FindUserByParamsQuery]{
			Reader: d.ViewReader, View: view.Name(),
		},
		fwgrpc.RequirePermission("users:read")))

	reg.Register(fwgrpc.QueryByID(usersv1connect.UsersServiceGetUserProcedure,
		(*usersv1.GetUserRequest).GetId,
		requests.GetUserPB{}.ToQuery,
		requests.GetUserPB{}.FromDoc,
		&handlers.FindByIDQueryHandler[*appqueries.FindUserByIDQuery]{
			Reader: d.ViewReader, View: view.Name(),
		},
		fwgrpc.RequirePermission("users:read")))

	reg.Register(fwgrpc.CommandByID(usersv1connect.UsersServiceArchiveUserProcedure,
		(*usersv1.ArchiveUserRequest).GetId,
		requests.ArchiveUserPB{}.FromResult,
		&handlers.ArchiveCommandHandler[*appdomain.User, *commands.ArchiveUserCommand, fwresults.None]{
			Repo: repo,
		},
		fwgrpc.RequirePermission("users:archive")))
}
