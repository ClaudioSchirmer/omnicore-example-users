package web

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/domain"
	fwinfra "github.com/ClaudioSchirmer/omnicore/infra"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	"github.com/ClaudioSchirmer/omnicore/web/export"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	apphandlers "github.com/ClaudioSchirmer/omnicore-example-users/application/handlers"
	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
	"github.com/ClaudioSchirmer/omnicore-example-users/web/requests"

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
// /health is not registered here — it comes from the framework.
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
	view *fwinfra.ViewDefinition,
	d bootstrap.Deps,
) {
	users := app.Group("/users")
	viewName := view.Name()

	insertH, insertSpec := fwweb.HandleCommandWithBodySpec(d.Pipeline,
		requests.InsertUserRequest{},
		requests.InsertUserResponse{}.FromResult,
		&handlers.InsertCommandHandler[*appdomain.User, *commands.InsertUserCommand, commands.InsertUserResult]{
			Repo: repo, Service: svc,
		}, fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodPost, "/",
		insertH, insertSpec,
		fwopenapi.Doc{
			Summary: "Create a user",
			Description: "Inserts a user with optional addresses as aggregate children. Validates root fields and each address through `BuildRules`; the `users_email_active_idx` unique partial index translates duplicates to 409 `EmailAlreadyExistsNotification`. Emits a single outbox row covering the aggregate snapshot — Debezium routes it to `users.events` and the SyncEngine projects the document to Mongo asynchronously (~100-300ms).",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:write"))

	updateH, updateSpec := fwweb.HandleCommandWithBodyIDSpec(d.Pipeline,
		requests.UpdateUserRequest{},
		requests.UpdateUserResponse{}.FromResult,
		&handlers.UpdateCommandHandler[*appdomain.User, *commands.UpdateUserCommand, commands.UpdateUserResult]{
			Repo: repo, Service: svc,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodPut, "/:id",
		updateH, updateSpec,
		fwopenapi.Doc{
			Summary: "Replace a user (full body)",
			Description: "Full replacement. Body is strict — the `FullBody` marker rejects requests missing any exported field with 400 `RequiredFieldNotification`. The `addresses` slice replaces the entire child collection atomically: items present in the previous aggregate but absent here become `REMOVED`; new ones become `ADDED`. The `EmailCannotChangeNotification` domain rule blocks email rename — attempting to change it returns 422.",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:write"))

	patchH, patchSpec := fwweb.HandleCommandWithBodyIDSpec(d.Pipeline,
		requests.PatchUserRequest{},
		requests.PatchUserResponse{}.FromResult,
		&handlers.PartialUpdateCommandHandler[*appdomain.User, *commands.PatchUserCommand, commands.PatchUserResult]{
			Repo: repo, Service: svc,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodPatch, "/:id",
		patchH, patchSpec,
		fwopenapi.Doc{
			Summary: "Patch a user (partial body)",
			Description: "Partial root update — only fields present in the body are applied; missing fields preserve their current value (empty body is a 200 noop). Address operations are NOT supported on PATCH; use PUT for atomic collection replacement. Does not accept `includeArchived` — state transitions live on the dedicated `/archive` and `/unarchive` endpoints.",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:write"))

	deleteH, deleteSpec := fwweb.HandleCommandWithIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.DeleteCommandHandler[*appdomain.User, *commands.DeleteUserCommand, fwresults.None]{
			Repo: repo, Service: svc,
		}, fiber.StatusNoContent)
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodDelete, "/:id",
		deleteH, deleteSpec,
		fwopenapi.Doc{
			Summary: "Hard-delete a user",
			Description: "Hard delete — irreversible. Removes the user row and cascades to addresses via FK `ON DELETE CASCADE`. Emits a `DELETED` outbox event; the SyncEngine drops the Mongo document unconditionally (regardless of the view's `DeleteOnArchive` flag — that opt-in only governs ARCHIVED). For reversible removal, use `/archive` instead.",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:delete"))

	archiveH, archiveSpec := fwweb.HandleCommandWithIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.ArchiveCommandHandler[*appdomain.User, *commands.ArchiveUserCommand, fwresults.None]{
			Repo: repo, Service: svc,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodPatch, "/:id/archive",
		archiveH, archiveSpec,
		fwopenapi.Doc{
			Summary: "Archive a user (cascade addresses)",
			Description: "Soft delete via `deleted_at = NOW()`. Aggregate-aware: the same TX archives every active address. Symmetric inverse of `/unarchive`. Layer-2 ownership applies — the JWT principal's email claim must match the persisted user's email unless they carry `users:admin` (super-admin bypass via `*:*`).",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:archive"))

	unarchiveH, unarchiveSpec := fwweb.HandleCommandWithIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.UnarchiveCommandHandler[*appdomain.User, *commands.UnarchiveUserCommand, fwresults.None]{
			Repo: repo, Service: svc,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodPatch, "/:id/unarchive",
		unarchiveH, unarchiveSpec,
		fwopenapi.Doc{
			Summary: "Unarchive a user (restore archived addresses)",
			Description: "Reverses `/archive`. Clears `deleted_at` on the root and on every child archived alongside it — cascade also restores children archived by earlier Update operations, not just those touched by the matching Archive. Emits `UNARCHIVED`; the SyncEngine re-composes and upserts the Mongo document.",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:archive"))

	listH, listSpec := fwweb.HandleQueryWithParamsSpec(d.Pipeline,
		requests.FindUsersByParamsRequest{},
		fwresponses.AutoFromDoc[requests.FindUsersByParamsResponse],
		&handlers.FindByParamsQueryHandler[*appqueries.FindUserByParamsQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary: "List users (paged + filter)",
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
	csvH, csvSpec := fwweb.HandleQueryAsCSVSpec(d.Pipeline,
		requests.FindUsersByParamsRequest{},
		view.ExportPlan(),
		d.Translator,
		view.ResolveMaxExportRows(d.Config.Query.MaxExportRows),
		"users",
		&handlers.FindByParamsQueryHandler[*appqueries.FindUserByParamsQuery]{
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
	xlsxH, xlsxSpec := fwweb.HandleQueryAsXLSXSpec(d.Pipeline,
		requests.FindUsersByParamsRequest{},
		view.ExportPlan(),
		d.Translator,
		view.ResolveMaxExportRows(d.Config.Query.MaxExportRows),
		"users",
		&handlers.FindByParamsQueryHandler[*appqueries.FindUserByParamsQuery]{
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

	byIDH, byIDSpec := fwweb.HandleQueryWithIDSpec(d.Pipeline,
		requests.FindUserByIDRequest{},
		fwresponses.AutoFromDoc[requests.FindUserByIDResponse],
		&handlers.FindByIDQueryHandler[*appqueries.FindUserByIDQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodGet, "/:id",
		byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary: "Get a user by id",
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

	changeAddrH, changeAddrSpec := fwweb.HandleCommandWithBodyIDSpec(d.Pipeline,
		requests.ChangeAddressRequest{},
		requests.ChangeAddressResponse{}.FromResult,
		&handlers.UpdateCommandHandler[*appdomain.User, *commands.ChangeAddressCommand, commands.ChangeAddressResult]{
			Repo: repo, Service: svc,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodPut, "/:id/addresses/:addressId",
		changeAddrH, changeAddrSpec,
		fwopenapi.Doc{
			Summary: "Replace one address inside a user (preserve address id)",
			Description: "Full replacement of one address child within the User aggregate, keeping the same `addresses.id`. Strict body — `FullBody` marker rejects any missing field with 400. The auditor pairs pre/post by `Address.GetID()` and emits `children.Address[*].op=\"changed\"` with the field-level delta — the canonical PUT /users/:id replace path produces `added`+`removed` instead because it wipes the collection. 404 on missing user id; 404 on user found but address id absent.",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:write"))

	findAddrH, findAddrSpec := fwweb.HandleQueryWithIDSpec(d.Pipeline,
		requests.FindAddressByIDRequest{},
		fwresponses.AutoFromDoc[requests.FindAddressByIDResponse],
		&apphandlers.FindAddressByIDQueryHandler{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, users, fiber.MethodGet, "/:id/addresses/:addressId",
		findAddrH, findAddrSpec,
		fwopenapi.Doc{
			Summary: "Get one address of a user by id",
			Description: "Loads the user document from the `users` Mongo view, walks the embedded `addresses[]`, and returns the entry whose `id` matches `:addressId`. `?includeArchived=true` follows the same semantic as GET /users/:id?includeArchived=true. 404 on missing user or address.",
			Tags:        []string{"Users"},
		},
		fwopenapi.RequirePermission("users:read"))
}
