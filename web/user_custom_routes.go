package web

import (
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/domain"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	appcmd "github.com/ClaudioSchirmer/omnicore-example-users/application/commands/handlers"
	appquery "github.com/ClaudioSchirmer/omnicore-example-users/application/queries/handlers"
	"github.com/ClaudioSchirmer/omnicore-example-users/web/requests"
	"github.com/ClaudioSchirmer/omnicore-example-users/web/responses"

	"github.com/gofiber/fiber/v3"
)

// usersViewName is the Mongo view this showcase reads from — same name
// declared in infra/views.go (UserView().Name()). Hardcoded here to avoid
// instantiating a duplicate ViewDefinition just to extract its name; the
// canonical UserView() is the source of truth and remains called once via
// UsersFeature for the SyncEngine registration.
const usersViewName = "users"

// MountUsersCustom registers the manual showcase of the User aggregate
// under /showcase/users-custom/*. Each route writes out the Fiber-handler
// equivalent of what fwweb.HandleCommandWithBody{,ID} / HandleCommandByID
// hide on the canonical /users/* surface:
//
//   1. fwweb.BindPath(c, &req) — every route, body-carrying and bodyless
//      alike, declares a Request DTO so the :email URL segment is read
//      via a tagged struct field instead of c.Params(). Bodyless routes
//      use the shared requests.UserCustomKeyRequest; body-carrying ones
//      use their endpoint-specific DTO (with the same path:"email" tag).
//   2. parse body (when applicable)
//   3. build AppContext + propagate the request's cancellation context (c)
//   4. assemble the Command — req.ToCommand() for body endpoints, an
//      inline one-liner mapping req.Email → cmd.EmailKey for bodyless
//   5. dispatch via pipeline.Dispatch
//   6. on Success →
//        - POST/PUT/PATCH: handler returns commands.UserCustomResult;
//          route maps it via responses.FromResult(result.Value()) and emits
//          via RespondWithSuccess. Result-intermediate is the canonical
//          shape — application returns a Go-pure DTO; web renames the
//          package by adding JSON tags.
//        - Archive/Unarchive: handler returns fwresults.None; route emits
//          envelope without `data` via RespondWithStatus.
//        - DELETE: 204 with no body via RespondFromResult.
//   7. on Failure / Exception → delegate to RespondFromResult, which honors
//      semanticToStatus (422/404/409/500) on the Result.Notifications.
//
// Parameters are interfaces — appcmd.ScopedUserRepository (the port
// declared by application/commands/handlers/) and domain.Service (framework
// abstraction over an injectable domain service). This file imports
// nothing from `appinfra`. The concrete *appinfra.UserCustomRepository
// and *appinfra.UserService are constructed by ShowcaseFeature (in
// bootstrap/, the composition root), and Go converts concrete → interface
// at the Mount call boundary. The handlers and routes only ever speak
// the interface — exactly the dependency-inversion the DDD layer ruler
// asks for.
func MountUsersCustom(
	app *fiber.App,
	repo appcmd.ScopedUserRepository,
	svc domain.Service,
	d bootstrap.Deps,
) {
	g := app.Group("/showcase/users-custom")
	tags := []string{"Users — manual showcase"}

	// QueryParsers are constructed once at Mount so the framework runs the
	// same boot scan HandleQueryWithParams runs on the canonical surface:
	// fields-side structural guard (panic on any field that violates the
	// sparse-render contract — *T + ,omitempty recursively) when the
	// Request opts into `?fields=`, sort-side advisory (slog.Warn listing
	// every sortable wire path so the operator can compare against the
	// view's index declaration) when the Request opts into `?sort=`. Both
	// parsers also build the wire→doc projection schema consumed by the
	// per-request Parse call for ?fields= and ?sort= translation.
	//
	// The byEmail parser carries no fields/sort opt-in today and therefore
	// runs in pass-through mode at construction (no guard, no warn) and
	// at runtime (projSchema=nil, identical behavior to fwweb.ParseCriteria
	// — the helper still exists for callers that have no typed Response).
	// Constructing it via NewQueryParser instead anchors the surface on the
	// canonical path so the day the by-email DTO opts in, the guard fires
	// without any wiring change here.
	listParser := fwweb.NewQueryParser[requests.FindUsersCustomRequest, requests.FindUsersCustomResponse]()
	byEmailParser := fwweb.NewQueryParser[requests.FindUserByEmailCustomRequest, requests.FindUserByEmailCustomResponse]()

	// Manual-with-pipeline routes route through openapi.Mount + a hand-crafted
	// RouteSpec because the wrappers' siblings (HandleCommandWith*Spec /
	// HandleQueryWith*Spec) only cover the canonical wrapper path. Both
	// surfaces register against the SAME d.OpenAPIRegistry — the showcase
	// proves the manual path is a first-class citizen on the documentation
	// layer, not a second-tier escape hatch.

	// POST /showcase/users-custom — the manual showcase's canonical
	// demonstration of Doc.RequestExamples + Doc.ResponseExamples. The
	// canonical /users/* surface stays clean (per-property `example:`
	// tags on the DTOs do the work there); this manual route absorbs the
	// rich-path showcase. Consumers see two distinct request payloads in
	// the dropdown ("minimal" without addresses, "withAddress" with one
	// full address) and one custom 409 example ("duplicateEmail") that
	// surfaces the wire shape when the email uniqueness violation fires
	// — alongside the framework's canonical entries auto-merged under
	// the "default" key on every standard error status.
	insertPhone := "14155552671"
	insertHome := "home"
	insertComplement := "Apt 4B"
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPost, "/",
		customInsertUser(d.Pipeline, repo, svc),
		fwopenapi.RouteSpecOf[requests.InsertUserCustomRequest, responses.UserCustomResponse](fiber.StatusCreated),
		fwopenapi.Doc{
			Summary:     "Create a user (manual showcase)",
			Description: "Manual hand-rolled equivalent of POST /users — same domain layer and persistence, hand-written application handler + Fiber handler exposing every step the canonical wrapper hides. Body shape is identical to the canonical endpoint; the success response carries the shared `UserCustomResponse` shape reused by Update and Patch on this surface.",
			Tags:        tags,
			RequestExamples: map[string]fwopenapi.Example{
				"minimal": {
					Summary: "Minimal valid payload (no addresses)",
					Value: requests.InsertUserCustomRequest{
						Name:  "Alice Pereira",
						Email: "alice@example.com",
						Phone: &insertPhone,
					},
				},
				"withAddress": {
					Summary: "With one home address",
					Value: requests.InsertUserCustomRequest{
						Name:  "Bob Pereira",
						Email: "bob@example.com",
						Phone: &insertPhone,
						Addresses: []requests.AddressCustomRequest{{
							Label:        &insertHome,
							Street:       "1 Infinite Loop",
							Number:       "1",
							Complement:   &insertComplement,
							Neighborhood: "Mariani",
							City:         "Cupertino",
							State:        "CA",
							ZipCode:      "95014",
							Country:      "US",
						}},
					},
				},
			},
			ResponseExamples: map[int]map[string]fwopenapi.Example{
				fiber.StatusConflict: {
					"duplicateEmail": {
						Summary: "Email already registered (uniqueness violation surfaced from infra)",
						Description: "Emitted when the unique partial index `users_email_active_idx` " +
							"rejects the INSERT (PG SQLSTATE 23505). The framework translates the " +
							"constraint into `EmailAlreadyExistsNotification` with semantic `Conflict`, " +
							"mapping to HTTP 409.",
						Value: map[string]any{
							"success":     false,
							"status":      409,
							"description": "Conflict",
							"errors": []any{
								map[string]any{
									"context": "User",
									"messages": []any{
										map[string]any{
											"notificationKey": "EmailAlreadyExistsNotification",
											"semantic":        "Conflict",
											"field":           "email",
											"value":           "alice@example.com",
											"message":         "Email already registered.",
										},
									},
								},
							},
						},
					},
				},
			},
		},
		fwopenapi.RequirePermission("users:write"))

	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPut, "/:email",
		customUpdateUser(d.Pipeline, repo, svc),
		fwopenapi.RouteSpecOf[requests.UpdateUserCustomRequest, responses.UserCustomResponse](fiber.StatusOK),
		fwopenapi.Doc{
			Summary:     "Replace a user by email (manual showcase)",
			Description: "Manual variant of PUT /users/:id keyed by email. The `:email` path segment is the immutable identifier on this surface — the request body has no `email` field. Loads the aggregate by email, replaces root fields plus the entire address collection, persists via the manual orchestration.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("users:write"))

	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:email",
		customPatchUser(d.Pipeline, repo, svc),
		fwopenapi.RouteSpecOf[requests.PatchUserCustomRequest, responses.UserCustomResponse](fiber.StatusOK),
		fwopenapi.Doc{
			Summary:     "Patch a user by email (manual showcase)",
			Description: "Manual variant of PATCH /users/:id keyed by email. Lenient partial body — empty body returns a 200 noop. Email is the path identifier and cannot be patched; rename via DELETE + POST on this surface, or use the canonical `/users/:id` PATCH.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("users:write"))

	// Archive / Unarchive align with the canonical: handler returns
	// fwresults.None, route emits envelope without `data` field via
	// RespondWithStatus on success. fwresponses.None is the spec-side
	// sentinel the OpenAPI assembler picks up to render "200 with no body"
	// — same shape used by DELETE below.
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:email/archive",
		customArchiveUser(d.Pipeline, repo, svc),
		fwopenapi.RouteSpecOf[requests.UserCustomKeyRequest, fwresponses.None](fiber.StatusOK),
		fwopenapi.Doc{
			Summary:     "Archive a user by email (manual showcase)",
			Description: "Manual variant of /users/:id/archive keyed by email. Aggregate-aware soft delete; the same TX archives every active address. Symmetric inverse of `/unarchive`.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("users:archive"))

	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:email/unarchive",
		customUnarchiveUser(d.Pipeline, repo, svc),
		fwopenapi.RouteSpecOf[requests.UserCustomKeyRequest, fwresponses.None](fiber.StatusOK),
		fwopenapi.Doc{
			Summary:     "Unarchive a user by email (manual showcase)",
			Description: "Manual variant of /users/:id/unarchive keyed by email. Restores every archived child of the root — same cascade semantic as the canonical surface (also restores children archived by earlier Update operations, not only those touched by the matching Archive).",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("users:archive"))

	// DELETE returns 204 with no body — responses.None is the canonical
	// sentinel the spec assembler picks up to emit the envelope without
	// the `data` field (matches the Auto wrappers' fwresults.None /
	// fwresponses.NoBody pairing on /users/:id).
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodDelete, "/:email",
		customDeleteUser(d.Pipeline, repo, svc),
		fwopenapi.RouteSpecOf[requests.UserCustomKeyRequest, fwresponses.None](fiber.StatusNoContent),
		fwopenapi.Doc{
			Summary:     "Hard-delete a user by email (manual showcase)",
			Description: "Manual variant of DELETE /users/:id keyed by email. Hard delete — irreversible; cascades to addresses via FK `ON DELETE CASCADE`. Use `/archive` for reversible removal.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("users:delete"))

	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/",
		customListUsers(d.Pipeline, d.ViewReader, listParser),
		fwopenapi.RouteSpecOfPaged[requests.FindUsersCustomRequest, requests.FindUsersCustomResponse](fiber.StatusOK),
		fwopenapi.Doc{
			Summary:     "List users (manual showcase)",
			Description: "Manual paged list with a reduced wire shape (`{id, name, email}` only — phone and addresses are stripped at the projection step). Allowlisted query keys: `?includeArchived`, `?limit`, `?after`, `?before`, `?name`, `?email`; unknown keys return 400 (same `SchemaViolationNotification` envelope the canonical surface emits).",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("users:read"))

	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:email",
		customGetUserByEmail(d.Pipeline, d.ViewReader, byEmailParser),
		fwopenapi.RouteSpecOf[requests.FindUserByEmailCustomRequest, requests.FindUserByEmailCustomResponse](fiber.StatusOK),
		fwopenapi.Doc{
			Summary:     "Get a user by email (manual showcase)",
			Description: "Manual single-item lookup keyed by email. Translates to a `Filter[Email]=<value>` + `Limit=1` ReadPage against the `users` Mongo view; empty result returns 404 `RecordNotFoundNotification`. Same reduced wire shape as the list endpoint. `?includeArchived=true` includes the archived document.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("users:read"))

	// ─── Address subresource — same as canonical /users/:id/addresses/* ────
	//
	// PUT /showcase/users-custom/:email/addresses/:addressId replaces ONE
	// existing address preserving its primary key — exercises the same
	// User.ChangeAddressByID domain method the canonical surface uses, so
	// the auditor emits identical children.Address[*].op="changed" lines
	// regardless of which path the consumer hit. The manual route loads
	// the user via FindByEmail (matching the surface's email-as-key
	// convention).
	//
	// GET /showcase/users-custom/:email/addresses/:addressId reads the
	// view doc via ReadPage with Filter[Email]+Limit:1, walks the embedded
	// addresses[], and returns the matching sub-document — projecting to
	// the reduced FindAddressByEmailAndIDResponse shape (id+street+city+
	// country) as a deliberate twin of the manual user-by-email reduced
	// shape.

	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPut, "/:email/addresses/:addressId",
		customChangeAddress(d.Pipeline, repo, svc),
		fwopenapi.RouteSpecOf[requests.ChangeAddressCustomRequest, responses.UserCustomResponse](fiber.StatusOK),
		fwopenapi.Doc{
			Summary: "Replace one address inside a user (manual showcase)",
			Description: "Manual hand-rolled variant of PUT /users/:id/addresses/:addressId keyed by email. Loads the aggregate via FindByEmail, looks up the address slot by id, replaces its fields preserving the same `addresses.id`. The auditor pairs pre/post by `Address.GetID()` and emits `children.Address[*].op=\"changed\"` with the field-level delta — exact same audit shape the canonical surface produces.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("users:write"))

	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:email/addresses/:addressId",
		customGetAddressByEmailAndID(d.Pipeline, d.ViewReader),
		fwopenapi.RouteSpecOf[requests.FindAddressByEmailAndIDRequest, requests.FindAddressByEmailAndIDResponse](fiber.StatusOK),
		fwopenapi.Doc{
			Summary: "Get one address of a user by email (manual showcase)",
			Description: "Manual single-item lookup of one address. Resolves the user via `Filter[Email]=<value>` + `Limit=1` ReadPage, walks the embedded `addresses[]`, returns the matching entry in the reduced shape `{id, street, city, country}` — twin of the manual user-by-email projection. 404 on missing user or missing address.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("users:read"))
}

// ─── POST /showcase/users-custom ───────────────────────────────────────────
//
// Uses dedicated InsertUserCustomRequest + InsertUserCustomCommand. Body
// shape is identical to the canonical POST, but the symbols are scoped to
// the manual showcase so only domain/ is reused across the two surfaces —
// matching the *CustomCommand twin pattern of Update/Patch/Archive/
// Unarchive/Delete.

func customInsertUser(
	pipe *pipeline.Pipeline,
	repo appcmd.ScopedUserRepository,
	svc domain.Service,
) fiber.Handler {
	return func(c fiber.Ctx) error {
		var req requests.InsertUserCustomRequest
		if err := c.Bind().Body(&req); err != nil {
			return respondCustomSchemaViolation(c)
		}

		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)

		cmd := req.ToCommand()
		h := &appcmd.InsertUserCustomCommandHandler{Repo: repo, Service: svc}

		result := pipeline.Dispatch(pipe, appCtx, cmd, h)
		if result.IsSuccess() {
			return fwweb.RespondWithSuccess(c, fiber.StatusCreated, responses.FromResult(result.Value()))
		}
		return fwweb.RespondFromResult(c, result, fiber.StatusCreated)
	}
}

// ─── PUT /showcase/users-custom/:email ─────────────────────────────────────

func customUpdateUser(
	pipe *pipeline.Pipeline,
	repo appcmd.ScopedUserRepository,
	svc domain.Service,
) fiber.Handler {
	return func(c fiber.Ctx) error {
		var req requests.UpdateUserCustomRequest
		if badField, ok := fwweb.BindPath(c, &req); !ok {
			return fwweb.RespondSchemaViolation(c, pipe, badField)
		}
		if err := c.Bind().Body(&req); err != nil {
			return respondCustomSchemaViolation(c)
		}

		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)

		cmd := req.ToCommand()
		h := &appcmd.UpdateUserCustomCommandHandler{Repo: repo, Service: svc}

		result := pipeline.Dispatch(pipe, appCtx, cmd, h)
		if result.IsSuccess() {
			return fwweb.RespondWithSuccess(c, fiber.StatusOK, responses.FromResult(result.Value()))
		}
		return fwweb.RespondFromResult(c, result, fiber.StatusOK)
	}
}

// ─── PATCH /showcase/users-custom/:email ───────────────────────────────────
//
// Lenient body: empty PATCH is OK (noop). Mirrors the canonical PATCH which
// also accepts empty body via the framework's PartialUpdate wrapper.

func customPatchUser(
	pipe *pipeline.Pipeline,
	repo appcmd.ScopedUserRepository,
	svc domain.Service,
) fiber.Handler {
	return func(c fiber.Ctx) error {
		var req requests.PatchUserCustomRequest
		if badField, ok := fwweb.BindPath(c, &req); !ok {
			return fwweb.RespondSchemaViolation(c, pipe, badField)
		}
		if len(c.Body()) > 0 {
			if err := c.Bind().Body(&req); err != nil {
				return respondCustomSchemaViolation(c)
			}
		}

		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)

		cmd := req.ToCommand()
		h := &appcmd.PatchUserCustomCommandHandler{Repo: repo, Service: svc}

		result := pipeline.Dispatch(pipe, appCtx, cmd, h)
		if result.IsSuccess() {
			return fwweb.RespondWithSuccess(c, fiber.StatusOK, responses.FromResult(result.Value()))
		}
		return fwweb.RespondFromResult(c, result, fiber.StatusOK)
	}
}

// ─── PATCH /showcase/users-custom/:email/archive ───────────────────────────
//
// Bodyless: no Bind().Body(). The shared UserCustomKeyRequest carries the
// :email path segment so the route exposes its identifier via a tagged
// struct field (same surface a reverse-engineering pass introspects on
// the body-carrying PUT/PATCH custom routes).
//
// Handler returns fwresults.None. On success the route uses RespondWithStatus
// to emit the envelope without a `data` field — same shape as the canonical
// Auto Archive wrapper, which detects responses.None at runtime and routes
// the success path through the same helper.

func customArchiveUser(
	pipe *pipeline.Pipeline,
	repo appcmd.ScopedUserRepository,
	svc domain.Service,
) fiber.Handler {
	return func(c fiber.Ctx) error {
		var req requests.UserCustomKeyRequest
		if badField, ok := fwweb.BindPath(c, &req); !ok {
			return fwweb.RespondSchemaViolation(c, pipe, badField)
		}

		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)

		cmd := &commands.ArchiveUserCustomCommand{EmailKey: req.Email}
		h := &appcmd.ArchiveUserCustomCommandHandler{Repo: repo, Service: svc}

		result := pipeline.Dispatch(pipe, appCtx, cmd, h)
		if result.IsSuccess() {
			return fwweb.RespondWithStatus(c, fiber.StatusOK)
		}
		return fwweb.RespondFromResult(c, result, fiber.StatusOK)
	}
}

// ─── PATCH /showcase/users-custom/:email/unarchive ─────────────────────────

func customUnarchiveUser(
	pipe *pipeline.Pipeline,
	repo appcmd.ScopedUserRepository,
	svc domain.Service,
) fiber.Handler {
	return func(c fiber.Ctx) error {
		var req requests.UserCustomKeyRequest
		if badField, ok := fwweb.BindPath(c, &req); !ok {
			return fwweb.RespondSchemaViolation(c, pipe, badField)
		}

		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)

		cmd := &commands.UnarchiveUserCustomCommand{EmailKey: req.Email}
		h := &appcmd.UnarchiveUserCustomCommandHandler{Repo: repo, Service: svc}

		result := pipeline.Dispatch(pipe, appCtx, cmd, h)
		if result.IsSuccess() {
			return fwweb.RespondWithStatus(c, fiber.StatusOK)
		}
		return fwweb.RespondFromResult(c, result, fiber.StatusOK)
	}
}

// ─── DELETE /showcase/users-custom/:email ──────────────────────────────────
//
// Returns 204 No Content on success — same convention as the canonical
// DELETE /users/:id. RespondFromResult honors the requested success status
// and emits an empty data field (struct{} pruned by json:"data,omitempty").

func customDeleteUser(
	pipe *pipeline.Pipeline,
	repo appcmd.ScopedUserRepository,
	svc domain.Service,
) fiber.Handler {
	return func(c fiber.Ctx) error {
		var req requests.UserCustomKeyRequest
		if badField, ok := fwweb.BindPath(c, &req); !ok {
			return fwweb.RespondSchemaViolation(c, pipe, badField)
		}

		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)

		cmd := &commands.DeleteUserCustomCommand{EmailKey: req.Email}
		h := &appcmd.DeleteUserCustomCommandHandler{Repo: repo, Service: svc}

		result := pipeline.Dispatch(pipe, appCtx, cmd, h)
		return fwweb.RespondFromResult(c, result, fiber.StatusNoContent)
	}
}

// ─── GET /showcase/users-custom/:email ─────────────────────────────────────
//
// By-email lookup. Translates to a single-item ReadPage with
// Filter[Email]=<value>; the application handler holds the canonical seam
// for row-level access control (see find_user_by_email_custom_handler.go).
// Returns the reduced wire shape (id + name + email) declared by
// requests.FindUserByEmailCustomResponse — phone and addresses are
// intentionally stripped at the projection step.
//
// Supports ?includeArchived=true|false (default false) so a consumer can
// read the archived snapshot — matches the canonical
// /users/:id?includeArchived=true behavior. Unknown query params are
// rejected with the canonical 400 envelope via the QueryParser constructed
// at Mount time (same allowlist HandleQueryWithParams runs internally).

func customGetUserByEmail(
	pipe *pipeline.Pipeline,
	reader fwqueries.ViewReader,
	parser *fwweb.QueryParser[requests.FindUserByEmailCustomRequest, requests.FindUserByEmailCustomResponse],
) fiber.Handler {
	return func(c fiber.Ctx) error {
		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)

		var req requests.FindUserByEmailCustomRequest
		if badField, ok := fwweb.BindPath(c, &req); !ok {
			return fwweb.RespondSchemaViolation(c, pipe, badField)
		}
		crit, badField, ok := parser.Parse(c)
		if !ok {
			return fwweb.RespondSchemaViolation(c, pipe, badField)
		}

		q := req.ToQuery(crit)
		h := &appquery.FindUserByEmailCustomQueryHandler{Reader: reader, View: usersViewName}

		result := pipeline.Dispatch(pipe, appCtx, q, h)
		if result.IsSuccess() {
			return fwweb.RespondWithSuccess(c, fiber.StatusOK,
				fwresponses.AutoFromDoc[requests.FindUserByEmailCustomResponse](result.Value()))
		}
		return fwweb.RespondFromResult(c, result, fiber.StatusOK)
	}
}

// ─── GET /showcase/users-custom ────────────────────────────────────────────
//
// Paged list. The route delegates to a Mount-time-constructed QueryParser
// that validates the query string against requests.FindUsersCustomRequest's
// `query:` and `filter:` tags — same reflection-based allowlist
// HandleQueryWithParams uses internally — AND threads the wire→doc
// projection schema built from FindUsersCustomResponse into ?fields=
// + ?sort= translation. The Request DTO opts into both reserved keys, so
// the parser's construction ran the sparse-render boot guard on the
// Response (every field *T + ,omitempty recursively) and emitted the
// slog.Warn advisory listing the sortable wire paths. Chaves desconhecidas
// viram 400 with the canonical SchemaViolationNotification envelope.
//
// Projection is fwresponses.AutoFromDoc — same tag-driven default the
// canonical /users surface uses. The manual route does NOT reimplement the
// projector by hand: `id`/`name`/`email` with auto _id-fallback would be a
// dumb rewrite of what AutoFromDoc already gives. What the manual surface
// makes visible is the OUTER mechanics (BindPath, QueryParser, Dispatch,
// RespondPaged) — those are the steps the canonical wrapper hides; the
// projector itself is shared infrastructure.
//
// On success the route delegates to fwweb.RespondPaged, which applies the
// projector per item and assembles the canonical envelope (Data carries
// the projected items, Pagination carries the cursor envelope at the top
// level) — same shape the auto wrapper produces. The manual path makes
// the wire assembly steps visible without having to hand-roll them.

func customListUsers(
	pipe *pipeline.Pipeline,
	reader fwqueries.ViewReader,
	parser *fwweb.QueryParser[requests.FindUsersCustomRequest, requests.FindUsersCustomResponse],
) fiber.Handler {
	return func(c fiber.Ctx) error {
		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)

		var req requests.FindUsersCustomRequest
		crit, badField, ok := parser.Parse(c)
		if !ok {
			return fwweb.RespondSchemaViolation(c, pipe, badField)
		}

		q := req.ToQuery(crit)
		h := &appquery.FindUsersCustomQueryHandler{Reader: reader, View: usersViewName}

		result := pipeline.Dispatch(pipe, appCtx, q, h)
		if !result.IsSuccess() {
			return fwweb.RespondFromResult(c, result, fiber.StatusOK)
		}
		return fwweb.RespondPaged(c, fiber.StatusOK, result.Value(),
			fwresponses.AutoFromDoc[requests.FindUsersCustomResponse])
	}
}

// ─── PUT /showcase/users-custom/:email/addresses/:addressId ────────────────
//
// Manual hand-rolled twin of PUT /users/:id/addresses/:addressId. Loads the
// user via FindByEmail, then calls the SAME domain method
// (User.ChangeAddressByID) the canonical Auto path uses — so the auditor
// emits the same `children.Address[*].op="changed"` shape regardless of
// which surface the consumer hit.

func customChangeAddress(
	pipe *pipeline.Pipeline,
	repo appcmd.ScopedUserRepository,
	svc domain.Service,
) fiber.Handler {
	return func(c fiber.Ctx) error {
		var req requests.ChangeAddressCustomRequest
		if badField, ok := fwweb.BindPath(c, &req); !ok {
			return fwweb.RespondSchemaViolation(c, pipe, badField)
		}
		if err := c.Bind().Body(&req); err != nil {
			return respondCustomSchemaViolation(c)
		}

		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)

		cmd := req.ToCommand()
		h := &appcmd.ChangeAddressCustomCommandHandler{Repo: repo, Service: svc}

		result := pipeline.Dispatch(pipe, appCtx, cmd, h)
		if result.IsSuccess() {
			return fwweb.RespondWithSuccess(c, fiber.StatusOK, responses.FromResult(result.Value()))
		}
		return fwweb.RespondFromResult(c, result, fiber.StatusOK)
	}
}

// ─── GET /showcase/users-custom/:email/addresses/:addressId ────────────────
//
// Manual twin of the canonical GET /users/:id/addresses/:addressId. Same
// projection (one address sub-document of the user view doc) reached via
// the email-keyed lookup the manual showcase uses on the read side.
// Reduced wire shape (id+street+city+country) demonstrates that view
// format and wire format are independent concerns — same view doc feeds
// canonical (full shape) and manual (reduced shape) projections.

func customGetAddressByEmailAndID(
	pipe *pipeline.Pipeline,
	reader fwqueries.ViewReader,
) fiber.Handler {
	return func(c fiber.Ctx) error {
		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)

		var req requests.FindAddressByEmailAndIDRequest
		if badField, ok := fwweb.BindPath(c, &req); !ok {
			return fwweb.RespondSchemaViolation(c, pipe, badField)
		}
		crit, badField, ok := fwweb.ParseCriteria(c, req)
		if !ok {
			return fwweb.RespondSchemaViolation(c, pipe, badField)
		}

		q := req.ToQuery(crit)
		h := &appquery.FindAddressByEmailAndIDQueryHandler{Reader: reader, View: usersViewName}

		result := pipeline.Dispatch(pipe, appCtx, q, h)
		if result.IsSuccess() {
			return fwweb.RespondWithSuccess(c, fiber.StatusOK,
				fwresponses.AutoFromDoc[requests.FindAddressByEmailAndIDResponse](result.Value()))
		}
		return fwweb.RespondFromResult(c, result, fiber.StatusOK)
	}
}

// respondCustomSchemaViolation is the manual showcase's substitute for the
// framework's package-private respondSchemaViolation. When the consumer
// sends malformed JSON, the canonical wrappers (HandleCommandWithBody) emit
// a typed SchemaViolationNotification carried in a Schema-semantic context;
// here we return the same 400 status with the bare envelope so the wire
// shape stays compatible, at the cost of the typed notificationKey. The
// limitation is documented in CLAUDE.md as a known trade-off of going
// fully manual on the body parse step.
func respondCustomSchemaViolation(c fiber.Ctx) error {
	return fwweb.Respond(c, fwweb.Response{
		Success:     false,
		Status:      fiber.StatusBadRequest,
		Description: "Bad Request",
		Errors: []fwweb.Error{{
			Context:  "Schema",
			Messages: []fwweb.ErrorMessage{{Message: "Malformed JSON body."}},
		}},
	})
}
