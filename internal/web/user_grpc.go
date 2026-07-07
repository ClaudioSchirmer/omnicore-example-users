package web

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	fwgrpc "github.com/ClaudioSchirmer/omnicore/web/grpc"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/web/requests"
	"github.com/ClaudioSchirmer/omnicore-example-users/proto/gen/usersv1"
	"github.com/ClaudioSchirmer/omnicore-example-users/proto/gen/usersv1/usersv1connect"
)

// MountUsersGRPC registers the User aggregate's RPCs into the service's
// single gRPC registry — the gRPC twin of MountUsers (REST) and
// MountUsersGraphQL: one declarative Register per RPC over the SAME
// ingredients the REST Spec constructors consume (the Request DTOs with
// their ToCommand/ToQuery, the Response DTOs' FromResult/AutoFromDoc).
// The framework bridges pb ↔ DTO mechanically at Register time (a
// contract/DTO mismatch aborts boot), so this file carries no marshalling
// — semantic transformation lives in the DTO seats, like every surface.
// Each procedure carries the same Layer-1 permission as its REST/GraphQL
// twin (enforced under auth.authorization.enabled, inert otherwise).
func MountUsersGRPC(
	reg *fwgrpc.Registry,
	repo persistence.ScopedRepository[*appdomain.User],
	view *query.ViewDefinition,
	d bootstrap.Deps,
) {
	reg.Register(fwgrpc.CommandWithBody[usersv1.CreateUserRequest, usersv1.CreateUserResponse](
		usersv1connect.UsersServiceCreateUserProcedure,
		requests.InsertUserRequest{},
		requests.InsertUserResponse{}.FromResult,
		&handlers.SharedBaseInsertCommandHandler[*appdomain.User, *commands.InsertUserCommand, commands.InsertUserResult]{
			Repo: repo,
		},
		fwgrpc.RequirePermission("users:write")))

	// WithBodyID: id + full body, strict (the PUT sibling — the handler
	// embeds FullBody; the Strict set mirrors the REST contract).
	reg.Register(fwgrpc.CommandWithBodyID[usersv1.UpdateUserRequest, usersv1.UpdateUserResponse](
		usersv1connect.UsersServiceUpdateUserProcedure,
		(*usersv1.UpdateUserRequest).GetId,
		requests.UpdateUserRequest{},
		requests.UpdateUserResponse{}.FromResult,
		&handlers.UpdateCommandHandler[*appdomain.User, *commands.UpdateUserCommand, commands.UpdateUserResult]{
			Repo: repo,
		},
		fwgrpc.Strict("id", "name", "email", "user_name"),
		fwgrpc.RequirePermission("users:write")))

	reg.Register(fwgrpc.QueryWithParams[usersv1.ListUsersRequest, usersv1.ListUsersResponse](
		usersv1connect.UsersServiceListUsersProcedure,
		requests.FindUsersByParamsRequest{},
		fwresponses.AutoFromDoc[requests.FindUsersByParamsResponse],
		&handlers.FindByParamsQueryHandler[*appqueries.FindUserByParamsQuery]{
			Reader: d.ViewReader, View: view.Name(),
		},
		fwgrpc.RequirePermission("users:read")))

	reg.Register(fwgrpc.QueryByID[usersv1.GetUserRequest, usersv1.GetUserResponse](
		usersv1connect.UsersServiceGetUserProcedure,
		(*usersv1.GetUserRequest).GetId,
		requests.FindUserByIDRequest{},
		fwresponses.AutoFromDoc[requests.FindUserByIDResponse],
		&handlers.FindByIDQueryHandler[*appqueries.FindUserByIDQuery]{
			Reader: d.ViewReader, View: view.Name(),
		},
		fwgrpc.RequirePermission("users:read")))

	reg.Register(fwgrpc.CommandByID[usersv1.ArchiveUserRequest, usersv1.ArchiveUserResponse, commands.ArchiveUserCommand](
		usersv1connect.UsersServiceArchiveUserProcedure,
		(*usersv1.ArchiveUserRequest).GetId,
		&handlers.ArchiveCommandHandler[*appdomain.User, *commands.ArchiveUserCommand, fwresults.None]{
			Repo: repo,
		},
		fwgrpc.RequirePermission("users:archive")))
}
