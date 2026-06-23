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
func MountUsersGraphQL(
	reg *fwgraphql.Registry,
	repo persistence.ScopedRepository[*appdomain.User],
	svc domain.Service,
	view *fwinfra.ViewDefinition,
	d bootstrap.Deps,
) {
	// READ → Query `users(where, first, after, orderBy, …)` → Relay connection.
	reg.Register(fwgraphql.Query[
		requests.FindUsersByParamsRequest,
		*appqueries.FindUserByParamsQuery,
		requests.FindUsersByParamsResponse,
	](
		"users", "User",
		&handlers.FindByParamsQueryHandler[*appqueries.FindUserByParamsQuery]{
			Reader: d.ViewReader, View: view.Name(),
		}))

	// WRITE insert → Mutation `createUser(input)` (input object reflected from
	// the Request DTO; NonNull fields follow the strict/lenient rule).
	reg.Register(fwgraphql.Mutation[
		requests.InsertUserRequest,
		commands.InsertUserCommand,
		*commands.InsertUserCommand,
		commands.InsertUserResult,
		requests.InsertUserResponse,
	](
		"createUser", requests.InsertUserResponse{}.FromResult,
		&handlers.InsertCommandHandler[*appdomain.User, *commands.InsertUserCommand, commands.InsertUserResult]{
			Repo: repo, Service: svc,
		}))

	// WRITE full update → MutationWithID `updateUser(id, input)` (PUT). The
	// UpdateCommandHandler embeds pipeline.FullBody, so the input object is
	// strict — every field NonNull.
	reg.Register(fwgraphql.MutationWithID[
		requests.UpdateUserRequest,
		commands.UpdateUserCommand,
		*commands.UpdateUserCommand,
		commands.UpdateUserResult,
		requests.UpdateUserResponse,
	](
		"updateUser", requests.UpdateUserResponse{}.FromResult,
		&handlers.UpdateCommandHandler[*appdomain.User, *commands.UpdateUserCommand, commands.UpdateUserResult]{
			Repo: repo, Service: svc,
		}))

	// WRITE partial update → MutationWithID `patchUser(id, input)` (PATCH). The
	// PartialUpdateCommandHandler is lenient, so the input fields are nullable
	// (pointer fields on the Request).
	reg.Register(fwgraphql.MutationWithID[
		requests.PatchUserRequest,
		commands.PatchUserCommand,
		*commands.PatchUserCommand,
		commands.PatchUserResult,
		requests.PatchUserResponse,
	](
		"patchUser", requests.PatchUserResponse{}.FromResult,
		&handlers.PartialUpdateCommandHandler[*appdomain.User, *commands.PatchUserCommand, commands.PatchUserResult]{
			Repo: repo, Service: svc,
		}))

	// WRITE bodyless → MutationByID → MutationResult{success, id}.
	reg.Register(fwgraphql.MutationByID[
		commands.ArchiveUserCommand, *commands.ArchiveUserCommand, fwresults.None,
	](
		"archiveUser",
		&handlers.ArchiveCommandHandler[*appdomain.User, *commands.ArchiveUserCommand, fwresults.None]{
			Repo: repo, Service: svc,
		}))

	reg.Register(fwgraphql.MutationByID[
		commands.UnarchiveUserCommand, *commands.UnarchiveUserCommand, fwresults.None,
	](
		"unarchiveUser",
		&handlers.UnarchiveCommandHandler[*appdomain.User, *commands.UnarchiveUserCommand, fwresults.None]{
			Repo: repo, Service: svc,
		}))

	reg.Register(fwgraphql.MutationByID[
		commands.DeleteUserCommand, *commands.DeleteUserCommand, fwresults.None,
	](
		"deleteUser",
		&handlers.DeleteCommandHandler[*appdomain.User, *commands.DeleteUserCommand, fwresults.None]{
			Repo: repo, Service: svc,
		}))
}
