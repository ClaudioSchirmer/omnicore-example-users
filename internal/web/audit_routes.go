package web

import (
	"github.com/ClaudioSchirmer/omnicore/application/audit"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	"github.com/ClaudioSchirmer/omnicore/application/translation"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/read"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"

	appquery "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries/handlers"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/web/requests"

	"github.com/gofiber/fiber/v3"
)

// MountAudit registers the canonical audit-read endpoint:
//
//	GET /audit/:aggregateId
//
// REQUIRES audit destinations to include `database`. The endpoint
// reads from the `audit_events` relational table; rows are written there
// only when `audit.destinations` in microservice.<profile>.yaml carries
// `database` (the default in this example service). A deploy that
// chooses `destinations: [slog]` (echo-only) or `destinations: []`
// (disabled) ships with this endpoint mounted but every aggregate read
// will return 200 with `data: []` — there is no row to read.
//
// When relational storage is disabled but the audit JSON must still be
// translated (consumed from slog/ELK, Kafka, a backup snapshot, etc.),
// the framework's translation helpers are independent of the storage:
//
//   - audit.RenderLabels(ev *AuditEvent, t *Translator, lang) — typed
//     in-process Go reader; replace FieldLabelKey with FieldLabel.
//   - audit.RenderLabelsInJSON(doc map[string]any, t *Translator, lang)
//     — for BI / Python / Node consumers parsing the JSON envelope
//     directly. Same shape, no struct dependency.
//
// In other words: this route is the canonical relational-backed reader; the
// translation primitives compose with whatever storage backs the
// audit JSON. Disabling relational storage does not lose label translation —
// only loses this specific HTTP surface.
//
// Pattern: manual handler + Pipeline.Dispatch. Same orchestration the
// /showcase/users-custom GET routes follow:
//
//  1. fwweb.AppContext(c) + SetParent(c) → cancellation context flows
//     all the way down to the driver.
//  2. fwweb.BindPath(c, &req) → reads :aggregateId into the path-tagged
//     Request DTO. Malformed segment surfaces the canonical 400 envelope
//     with SchemaViolationNotification.
//  3. req.ToQuery() → the body-only web→application boundary mapper.
//     Hardcodes EntityType="User" (see find_audit_by_aggregate.go
//     for the extension story).
//  4. pipeline.Dispatch → the manual handler calls audit.FindByAggregate
//     against the relational engine and applies audit.RenderLabels in the
//     actor's locale before returning.
//  5. RespondWithSuccess wraps the slice in the canonical envelope
//     ({success, status, data}).
//
// Auth: gated with RequirePermission("audit:read"). The Keycloak realm
// fixture in devops/keycloak/ does not declare this scope today; the
// gate noops under auth.mode=disabled (dev profile) so the route works
// during local development, and rejects every request under auth.mode=
// jwt + authorization.enabled=true. Operators wiring `prd-authz` should
// add `audit:read` to the appropriate Keycloak client / role / user
// before deploying.
//
// The framework's audit.FindByID(ctx, exec, uuid) sibling is exposed
// for the forensic single-row lookup when an audit id is known from
// the slog echo; this route deliberately exposes only the timeline
// reader because (a) it is the common case and (b) the by-id read has
// a different access-control story (no aggregate-scoped owner check).
// A dedicated GET /audit/event/:id endpoint would be the next addition
// if forensic ergonomics demand it.
func MountAudit(app *fiber.App, d bootstrap.Deps) {
	g := app.Group("/audit")
	tags := []string{"Audit"}

	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:aggregateId",
		findAuditByAggregateHandler(d.Pipeline, read.NewAuditReader(d.DB), d.Translator),
		fwopenapi.RouteSpecOf[requests.FindAuditByAggregateRequest, requests.FindAuditByAggregateResponse](fiber.StatusOK),
		fwopenapi.Doc{
			Summary:     "Get the audit timeline of an aggregate",
			Description: "Returns every audit_events row for the supplied aggregate, newest first. Index-served by audit_events_entity_timeline_idx (entity_type, aggregate_id, occurred_at DESC). Each FieldChange carries its label translated into the actor's locale via Accept-Language — see CLAUDE.md \"Field labels\". Empty timeline (no rows for the aggregate) returns 200 with `data: []`.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("audit:read"))
}

// findAuditByAggregateHandler is the Fiber-level handler the route
// registers. Walks the canonical chain: AppContext → BindPath → ToQuery
// → Dispatch → RespondWithSuccess on hit / RespondFromResult on failure.
//
// Receives the persistent dependencies (Pipeline + relational engine + Translator)
// and constructs the application handler INSIDE the per-request closure
// — same convention every /showcase/users-custom route follows
// (customInsertUser, customUpdateUser, etc.). Application handlers are
// never cached on the feature struct; the feature holds only infra-level
// adapters that need wrapping or configuration. See CLAUDE.md "Feature
// struct convention" for the rationale.
//
// The handler's error path goes through pipeline.Dispatch's standard
// Result envelope: a SQL transport failure surfaces as Result.Exception
// → 500 InternalServerErrorNotification on the wire; a domain-shaped
// rejection (none expected from audit.FindByAggregate today, but the
// envelope tolerates it) would land as Result.Failure with the typed
// semantic. Same shape every other manual showcase route produces.
func findAuditByAggregateHandler(
	pipe *pipeline.Pipeline,
	reader audit.Reader,
	translator *translation.Translator,
) fiber.Handler {
	return func(c fiber.Ctx) error {
		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)

		var req requests.FindAuditByAggregateRequest
		if badField, ok := fwweb.BindPath(c, &req); !ok {
			return fwweb.RespondSchemaViolation(c, pipe, badField)
		}

		q := req.ToQuery()
		h := &appquery.FindAuditByAggregateQueryHandler{
			Reader:     reader,
			Translator: translator,
		}
		result := pipeline.Dispatch(pipe, appCtx, q, h)
		if result.IsSuccess() {
			return fwweb.RespondWithSuccess(c, fiber.StatusOK, result.Value())
		}
		return fwweb.RespondFromResult(c, result, fiber.StatusOK)
	}
}
