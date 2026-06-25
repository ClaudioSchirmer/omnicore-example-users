package web

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/domain"
	fwinfra "github.com/ClaudioSchirmer/omnicore/infra"
	fwgraphql "github.com/ClaudioSchirmer/omnicore/web/graphql"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
	"github.com/ClaudioSchirmer/omnicore-example-users/web/requests"
)

// MountUsersGraphQL registers the User aggregate's GraphQL fields into the
// service's single GraphQL registry — the GraphQL twin of MountUsers. GraphQL
// is ONE endpoint (POST /graphql) backed by ONE registry created in bootstrap;
// registration is cumulative, so each aggregate contributes its fields into the
// same `reg` (a future MountOrdersGraphQL(reg, …) just adds more). This is the
// exact parallel of REST's "one app, many MountXxx" — here "one graph, many
// contributions".
//
// It reuses the SAME application handlers MountUsers attaches to REST; the only
// thing shared between the two surfaces is those handlers. GraphQL never goes
// through openapi.Mount, never appears in the Swagger document, and is not
// policed by the REST route scans. The feature owns the repo/service/view it
// passes in; web owns the field attachment.
//
// Each field carries the same Layer-1 permission as its REST twin via
// fwgraphql.RequirePermission (the GraphQL twin of fwopenapi.RequirePermission):
// users → users:read; createUser/updateUser/patchUser → users:write;
// archiveUser/unarchiveUser → users:archive; deleteUser → users:delete. The
// gate enforces under auth.authorization.enabled (prd-authz) and is inert
// otherwise, exactly like the REST matrix.
func MountUsersGraphQL(
	reg *fwgraphql.Registry,
	repo persistence.ScopedRepository[*appdomain.User],
	svc domain.Service,
	view *fwinfra.ViewDefinition,
	d bootstrap.Deps,
) {
	// READ → QueryWithParams `users(where, first, after, orderBy, …)` → Relay connection.
	reg.Register(fwgraphql.QueryWithParams[
		requests.FindUsersByParamsRequest,
		requests.FindUsersByParamsResponse,
	](
		"users", "User",
		&handlers.FindByParamsQueryHandler[*appqueries.FindUserByParamsQuery]{
			Reader: d.ViewReader, View: view.Name(),
		},
		fwgraphql.RequirePermission("users:read")))

	// WRITE insert → MutationWithBody `createUser(input)` (input object reflected from
	// the Request DTO; NonNull fields follow the strict/lenient rule).
	reg.Register(fwgraphql.MutationWithBody[requests.InsertUserRequest](
		"createUser", requests.InsertUserResponse{}.FromResult,
		&handlers.InsertCommandHandler[*appdomain.User, *commands.InsertUserCommand, commands.InsertUserResult]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("users:write")))

	// WRITE full update → MutationWithBodyID `updateUser(id, input)` (PUT). The
	// UpdateCommandHandler embeds pipeline.FullBody, so the input object is
	// strict — every field NonNull.
	reg.Register(fwgraphql.MutationWithBodyID[requests.UpdateUserRequest](
		"updateUser", requests.UpdateUserResponse{}.FromResult,
		&handlers.UpdateCommandHandler[*appdomain.User, *commands.UpdateUserCommand, commands.UpdateUserResult]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("users:write")))

	// WRITE partial update → MutationWithBodyID `patchUser(id, input)` (PATCH). The
	// PartialUpdateCommandHandler is lenient, so the input fields are nullable
	// (pointer fields on the Request).
	reg.Register(fwgraphql.MutationWithBodyID[requests.PatchUserRequest](
		"patchUser", requests.PatchUserResponse{}.FromResult,
		&handlers.PartialUpdateCommandHandler[*appdomain.User, *commands.PatchUserCommand, commands.PatchUserResult]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("users:write")))

	// WRITE bodyless → MutationByID → MutationResult{success, id}.
	reg.Register(fwgraphql.MutationByID(
		"archiveUser",
		&handlers.ArchiveCommandHandler[*appdomain.User, *commands.ArchiveUserCommand, fwresults.None]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("users:archive")))

	reg.Register(fwgraphql.MutationByID(
		"unarchiveUser",
		&handlers.UnarchiveCommandHandler[*appdomain.User, *commands.UnarchiveUserCommand, fwresults.None]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("users:archive")))

	reg.Register(fwgraphql.MutationByID(
		"deleteUser",
		&handlers.DeleteCommandHandler[*appdomain.User, *commands.DeleteUserCommand, fwresults.None]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("users:delete")))
}
