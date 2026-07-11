package web

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	"github.com/ClaudioSchirmer/omnicore/web/export"
	fwgraphql "github.com/ClaudioSchirmer/omnicore/web/graphql"
	fwgrpc "github.com/ClaudioSchirmer/omnicore/web/grpc"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
	appquery "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries/handlers"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/web/requests"
	"github.com/ClaudioSchirmer/omnicore-example-users/proto/gen/usersv1"
	"github.com/ClaudioSchirmer/omnicore-example-users/proto/gen/usersv1/usersv1connect"

	"github.com/gofiber/fiber/v3"
)

// MountUsers registers the write + query routes for the User aggregate.
// Called by UsersFeature.Mount after receiving the already-built
// repo + service + view name. Two changes over the pre-OpenAPI wiring:
// (a) each route uses the *Spec sibling wrapper that returns
// (fiber.Handler, openapi.RouteSpec), and (b) registration goes through
// openapi.Mount instead of users.Post/Put/.../Get so the route lands
// both on Fiber AND on d.OpenAPIRegistry when OpenAPI is enabled. When
// d.OpenAPIRegistry is nil (Wiring.OpenAPI not set), openapi.Mount
// falls back to a thin Fiber-only passthrough, so this code works
// identically whether the spec is being generated or not.
//
// The /livez + /readyz probes are not registered here — they come from the framework.
//
// The PUT vs PATCH distinction still lives in the handler:
//   - UpdateCommandHandler embeds pipeline.FullBody → wrapper requires a
//     complete body; sibling wrapper sets RouteSpec.Strict=true.
//   - PartialUpdateCommandHandler is lenient → partial body OK;
//     RouteSpec.Strict=false.
//
// Response projection — per-endpoint:
//   - Insert/Update/Patch carry a custom Result + Response pair that the
//     siblings turn into a typed `data` field on the success envelope.
//   - Archive/Unarchive/Delete use fwresults.None + fwresponses.NoBody;
//     the framework detects responses.None and emits the envelope WITHOUT
//     a "data" field on both the runtime and the OpenAPI spec sides.
func MountUsers(
	app *fiber.App,
	repo persistence.ScopedRepository[*appdomain.User],
	svc domain.Service,
	view *query.ViewDefinition,
	d bootstrap.Deps,
) {
	users := app.Group("/users")
	viewName := view.Name()

	insertH, insertSpec := fwweb.CommandWithBodySpec(d.Pipeline,
		requests.InsertUserRequest{},
		requests.InsertUserResponse{}.FromResult,
		&handlers.SharedBaseInsertCommandHandler[*appdomain.User, *commands.InsertUserCommand, commands.InsertUserResult]{
			Repo: repo, Service: svc,
		}, fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodPost, "/",
		insertH, insertSpec,
		fwopenapi.Doc{
			Summary:     "Create a user",
			Description: "Creates a user backed by the shared Person identity (SharedBase). Because the person is deduplicated by `document` (the natural key), this POST is an UPSERT: the framework loads any existing person by document first, then the command applies the request on top — so a new person+user is created, or an existing person gains its user (its shared fields updated last-write-wins, its addresses deduped). Re-POSTing the same document for a person who already has an ACTIVE user returns 409 `EntityAlreadyAddedNotification`; an ARCHIVED user is invisible to the insert (soft-delete is delete) and the shared-PK remnant vetoes the write — the same 409, with `PATCH /users/:id/archive`'s inverse (`/unarchive`) as the explicit way back. The notification flags persist to the `user_configurations` sibling table. Emits the aggregate outbox row plus a person-base event the SyncEngine fans out; the Mongo document lands asynchronously (~100-300ms).",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:write"))

	updateH, updateSpec := fwweb.CommandWithBodyIDSpec(d.Pipeline,
		requests.UpdateUserRequest{},
		requests.UpdateUserResponse{}.FromResult,
		&handlers.UpdateCommandHandler[*appdomain.User, *commands.UpdateUserCommand, commands.UpdateUserResult]{
			Repo: repo, Service: svc,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodPut, "/:id",
		updateH, updateSpec,
		fwopenapi.Doc{
			Summary:     "Replace a user (full body)",
			Description: "Full replacement. Body is strict — the `FullBody` marker rejects requests missing any exported field with 400 `RequiredFieldNotification`. The shared Person fields (name/email/phone) are updated last-write-wins on the base; `userName` updates the role; the notification flags upsert (or, sent null in a PUT, clear) the `user_configurations` sibling. The `addresses` slice replaces the person's address collection atomically: items present before but absent here become `REMOVED`; new ones `ADDED`. `document` is the immutable natural key and is not part of the body; the `DocumentCannotChangeNotification` rule guards any attempt to change it (422).",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:write"))

	patchH, patchSpec := fwweb.CommandWithBodyIDSpec(d.Pipeline,
		requests.PatchUserRequest{},
		requests.PatchUserResponse{}.FromResult,
		&handlers.PartialUpdateCommandHandler[*appdomain.User, *commands.PatchUserCommand, commands.PatchUserResult]{
			Repo: repo, Service: svc,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodPatch, "/:id",
		patchH, patchSpec,
		fwopenapi.Doc{
			Summary:     "Patch a user (partial body)",
			Description: "Partial root update — only fields present in the body are applied; missing fields preserve their current value (empty body is a 200 noop). Address operations are NOT supported on PATCH; use PUT for atomic collection replacement. Does not accept `includeArchived` — state transitions live on the dedicated `/archive` and `/unarchive` endpoints.",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:write"))

	deleteH, deleteSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.DeleteCommandHandler[*appdomain.User, *commands.DeleteUserCommand, fwresults.None]{
			Repo: repo, Service: svc,
		}, fiber.StatusNoContent)
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodDelete, "/:id",
		deleteH, deleteSpec,
		fwopenapi.Doc{
			Summary:     "Hard-delete a user",
			Description: "Hard delete — irreversible. Removes the user (role) row; the framework then reference-counts the shared Person. The framework default is `KeepOrphan` (omission never destroys the identity); this service opts into physical erasure explicitly via `OrphanPolicy(DeleteWhenUnreferenced)`, so with no remaining role referencing it the person and its addresses are hard-deleted too — explicitly in Go, same TX. The purge runs under a savepoint and is database-vetoable: a foreign-key violation from ANY table still referencing the person (the role→persons FKs are declared `RESTRICT` to give the veto teeth) cancels the purge — the person stays, the user delete still commits. An actual purge is never invisible: it emits its own in-TX audit event (`entityType` = `persons`) and its own `DELETED` outbox row for the base, alongside the user's `DELETED` event; the SyncEngine drops the Mongo document unconditionally (regardless of the view's `DeleteOnArchive` flag — that opt-in only governs ARCHIVED). For reversible removal, use `/archive` instead.",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:delete"))

	archiveH, archiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.ArchiveCommandHandler[*appdomain.User, *commands.ArchiveUserCommand, fwresults.None]{
			Repo: repo, Service: svc,
		}, fiber.StatusNoContent)
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodPatch, "/:id/archive",
		archiveH, archiveSpec,
		fwopenapi.Doc{
			Summary:     "Archive a user (cascade addresses)",
			Description: "Soft delete via `deleted_at = NOW()`. Aggregate-aware: the same TX archives every active address. Symmetric inverse of `/unarchive`. Layer-2 ownership applies — the JWT principal's email claim must match the persisted user's email unless they carry `users:admin` (super-admin bypass via `*:*`).",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:archive"))

	unarchiveH, unarchiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.UnarchiveCommandHandler[*appdomain.User, *commands.UnarchiveUserCommand, fwresults.None]{
			Repo: repo, Service: svc,
		}, fiber.StatusNoContent)
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodPatch, "/:id/unarchive",
		unarchiveH, unarchiveSpec,
		fwopenapi.Doc{
			Summary:     "Unarchive a user (restore archived addresses)",
			Description: "Reverses `/archive`. Clears `deleted_at` on the root and on every child archived alongside it — cascade also restores children archived by earlier Update operations, not just those touched by the matching Archive. Emits `UNARCHIVED`; the SyncEngine re-composes and upserts the Mongo document.",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:archive"))

	listH, listSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		requests.FindUsersByParamsRequest{},
		fwresponses.AutoFromDoc[requests.FindUsersByParamsResponse],
		&handlers.FindByParamsQueryHandler[*appqueries.FindUsersByParamsQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List users (paged + filter)",
			Description: "Paged read against the `users` Mongo view. Filter operators are declared by struct tag (e.g. `filter:\"eq,in,startswith\"`); unknown query keys or operators outside the allowlist return 400 `SchemaViolationNotification`. Multiple operators on the same field AND-combine. Pass `?includeArchived=true` to include archived users; default hides them.",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:read"))

	// CSV export — same Request DTO, same view query handler as GET /users,
	// rendered as a hierarchical CSV (root columns at A, addresses at B…).
	// Headers come from the `labelKey:"…"` tags on User/Address resolved per
	// Accept-Language; `?fields=` narrows columns; filters/`?search`/`?sort`
	// work like the JSON list. User pagination is ignored — the export streams
	// the full filtered set capped at the resolved maxExportRows. Registered at
	// the app root (`/users.csv`) to avoid colliding with `/users/:id`. The ';'
	// delimiter is a showcase of the mount-time CSV option.
	csvH, csvSpec := fwweb.QueryAsCSVSpec(d.Pipeline,
		requests.FindUsersByParamsRequest{},
		view,
		d.Export,
		&handlers.FindByParamsQueryHandler[*appqueries.FindUsersByParamsQuery]{
			Reader: d.ViewReader, View: viewName,
		},
		export.WithDelimiter(','))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/users.csv",
		csvH, csvSpec,
		fwopenapi.Doc{
			Summary:     "Export users as CSV",
			Description: "Streams the same `users` view read as GET /users — same filter allowlist, `?search`, `?sort`, `?includeArchived`, `?fields=` — rendered as a hierarchical CSV: root columns start at column A, each address at column B (one column per nesting level). Column headers are the fields' `labelKey` catalog entries rendered in the request's `Accept-Language`. User pagination (`?limit`/`?after`/`?before`/`?onlyTotal`) is ignored — the export returns the full filtered set capped at `query.maxExportRows`. Field separator is `;`.",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:read"))

	// XLSX export — identical surface to /users.csv, different encoder. The
	// format-neutral core (ExportPlan + Generate) is reused verbatim; only the
	// encoder swaps. Headers are bold, numeric/typed cells stay typed, and the
	// per-level offset becomes the spreadsheet's own column offset.
	xlsxH, xlsxSpec := fwweb.QueryAsXLSXSpec(d.Pipeline,
		requests.FindUsersByParamsRequest{},
		view,
		d.Export,
		&handlers.FindByParamsQueryHandler[*appqueries.FindUsersByParamsQuery]{
			Reader: d.ViewReader, View: viewName,
		},
		export.WithSheetName("Users"))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/users.xlsx",
		xlsxH, xlsxSpec,
		fwopenapi.Doc{
			Summary:     "Export users as Excel (.xlsx)",
			Description: "Same surface as `GET /users.csv` — same filter allowlist, `?fields=`, `?search`, `?sort`, `?includeArchived`, same hierarchical layout and labelKey headers — serialized as an Excel workbook instead of CSV. Header rows are bold and numeric columns keep their numeric cell type. Demonstrates the format-pluggable export: only the encoder differs between this route and `/users.csv`.",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:read"))

	byIDH, byIDSpec := fwweb.QueryByIDSpec(d.Pipeline,
		requests.FindUserByIDRequest{},
		fwresponses.AutoFromDoc[requests.FindUserByIDResponse],
		&handlers.FindByIDQueryHandler[*appqueries.FindUserByIDQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodGet, "/:id",
		byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary:     "Get a user by id",
			Description: "Fetches the denormalized user document (root + addresses[]) from the `users` Mongo view. Only `?includeArchived=true` is recognized — any other query key returns 400. Returns 404 when the document is absent or filtered out by `?includeArchived`.",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:read"))

	// ─── Address subresource — child of the User aggregate ─────────────────
	//
	// PUT /users/:id/addresses/:addressId replaces ONE existing address
	// preserving its primary key. UpdateCommandHandler is reused — the
	// loaded aggregate has its targeted child slot flipped to CHANGED via
	// User.ChangeAddressByID, then the auditor pairs pre/post by
	// Address.GetID() and emits the canonical op=changed with the
	// field-level delta. This is the only path that exercises op=changed
	// today: the PUT /users/:id full-replace empties the collection and
	// emits added+removed instead.
	//
	// GET /users/:id/addresses/:addressId reads the user doc from the
	// users Mongo view, walks the embedded addresses[], and returns the
	// matching sub-document via FindAddressByIDQueryHandler — a hand-rolled
	// handler because the framework has no Auto "child of view doc" path.

	changeAddrH, changeAddrSpec := fwweb.CommandWithBodyIDSpec(d.Pipeline,
		requests.ChangeAddressRequest{},
		requests.ChangeAddressResponse{}.FromResult,
		&handlers.UpdateCommandHandler[*appdomain.User, *commands.ChangeAddressCommand, commands.ChangeAddressResult]{
			Repo: repo, Service: svc,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodPut, "/:id/addresses/:addressId",
		changeAddrH, changeAddrSpec,
		fwopenapi.Doc{
			Summary:     "Replace one address inside a user (preserve address id)",
			Description: "Full replacement of one address child within the User aggregate, keeping the same `addresses.id`. Strict body — `FullBody` marker rejects any missing field with 400. The auditor pairs pre/post by `Address.GetID()` and emits `children.Address[*].op=\"changed\"` with the field-level delta — the canonical PUT /users/:id replace path produces `added`+`removed` instead because it wipes the collection. 404 on missing user id; 404 on user found but address id absent.",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:write"))

	findAddrH, findAddrSpec := fwweb.QueryByIDSpec(d.Pipeline,
		requests.FindAddressByIDRequest{},
		fwresponses.AutoFromDoc[requests.FindAddressByIDResponse],
		&appquery.FindAddressByIDQueryHandler{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodGet, "/:id/addresses/:addressId",
		findAddrH, findAddrSpec,
		fwopenapi.Doc{
			Summary:     "Get one address of a user by id",
			Description: "Loads the user document from the `users` Mongo view, walks the embedded `addresses[]`, and returns the entry whose `id` matches `:addressId`. `?includeArchived=true` follows the same semantic as GET /users/:id?includeArchived=true. 404 on missing user or address.",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:read"))
}

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
	view *query.ViewDefinition,
	d bootstrap.Deps,
) {
	// READ → QueryWithParams `users(where, first, after, orderBy, …)` → Relay connection.
	reg.Register(fwgraphql.QueryWithParams[
		requests.FindUsersByParamsRequest,
		requests.FindUsersByParamsResponse,
	](
		"users", "User",
		&handlers.FindByParamsQueryHandler[*appqueries.FindUsersByParamsQuery]{
			Reader: d.ViewReader, View: view.Name(),
		},
		fwgraphql.RequirePermission("users:read")))

	// WRITE insert → MutationWithBody `createUser(input)` (input object reflected from
	// the Request DTO; NonNull fields follow the strict/lenient rule). The User is
	// SharedBase-backed, so the POST is an UPSERT — the same SharedBaseInsertCommandHandler
	// the REST surface uses (a duplicate active user for a document is a 409; an
	// archived one is invisible to the insert and its remnant vetoes on the PK — same 409).
	reg.Register(fwgraphql.MutationWithBody[requests.InsertUserRequest](
		"createUser", requests.InsertUserResponse{}.FromResult,
		&handlers.SharedBaseInsertCommandHandler[*appdomain.User, *commands.InsertUserCommand, commands.InsertUserResult]{
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
		&handlers.FindByParamsQueryHandler[*appqueries.FindUsersByParamsQuery]{
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
