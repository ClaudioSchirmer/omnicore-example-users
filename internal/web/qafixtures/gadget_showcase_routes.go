//go:build qa

package qafixtures

import (
	"strconv"
	"time"

	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"

	"github.com/gofiber/fiber/v3"
)

// defaultSlowSleepMillis is the sleep applied to GET /qa/showcase/slow when the
// caller omits ?sleepMillis. Chosen high enough to reliably outlast a low
// http.requestTimeoutSeconds (the 504 trigger) without wedging a suite that
// forgets to set one.
const defaultSlowSleepMillis = 3000

// MountGadgetShowcase registers the QA-only status-code + read-side-option
// showcase routes:
//
//	GET /qa/showcase/panic        → 500 (forced panic, recovered by fwweb.Recover)
//	GET /qa/showcase/unavailable  → 503 (ServiceUnavailableNotification)
//	GET /qa/showcase/slow         → 504 when the sleep outlasts the request budget
//	GET /qa/showcase/echo-values  → 400 carrying one message per echoed value type
//	GET /qa/gadgets-hot           list over the DeleteOnArchive `gadgets_hot` view
//	GET /qa/gadgets-capped        list over the MaxLimit(5) `gadgets_capped` view
//	GET /qa/gadgets-raw           list over `gadgets` mounted via MountRaw
//
// hotView / cappedView / defaultView are the Mongo collection names the feature
// registered (infraqa.GadgetHotView / GadgetCappedView / GadgetView).
func MountGadgetShowcase(
	app *fiber.App,
	hotView, cappedView, defaultView string,
	d bootstrap.Deps,
) {
	sc := app.Group("/qa/showcase")
	// Every Fiber route must be registered through openapi.Mount / MountRaw — the
	// framework's boot guard rejects routes on any other channel (spec, authz
	// gate, and boot validation share one registration path). These are raw
	// handlers, so they use MountRaw with a minimal (hidden) spec.
	scTags := []string{"QA Showcase"}

	// 500 — a raw route that panics. The app-level fwweb.Recover() middleware
	// (registered by bootstrap.Run) catches it and the ErrorHandler emits the
	// canonical 500 envelope carrying InternalServerErrorNotification.
	fwopenapi.MountRaw(d.OpenAPIRegistry, sc, fiber.MethodGet, "/panic",
		func(c fiber.Ctx) error { panic("qa showcase forced panic") },
		fwopenapi.RawSpec{
			Summary:     "Force a panic → 500 (recover path)",
			Description: "Panics; fwweb.Recover() catches it and the ErrorHandler emits a 500 InternalServerErrorNotification envelope.",
			Tags:        scTags, Public: true, Hidden: true,
		})

	// 503 — dispatch a query whose handler always fails with
	// ServiceUnavailableNotification. Same pipeline + RespondFromResult path as
	// every read; the notification's SemanticUnavailable maps to 503.
	fwopenapi.MountRaw(d.OpenAPIRegistry, sc, fiber.MethodGet, "/unavailable",
		func(c fiber.Ctx) error {
			appCtx := fwweb.AppContext(c)
			appCtx.SetParentIfAbsent(c)
			result := pipeline.Dispatch(d.Pipeline, appCtx,
				&appqa.UnavailableGadgetQuery{}, &appqa.UnavailableGadgetHandler{})
			return fwweb.RespondFromResult(c, result, fiber.StatusOK)
		},
		fwopenapi.RawSpec{
			Summary:     "Emit ServiceUnavailableNotification → 503",
			Description: "A query handler that always fails with ServiceUnavailableNotification (SemanticUnavailable → 503).",
			Tags:        scTags, Public: true, Hidden: true,
		})

	// 504 — dispatch a query that sleeps ?sleepMillis while honoring the request
	// context deadline. Under a low http.requestTimeoutSeconds the deadline fires
	// first, the handler returns context.DeadlineExceeded, and pipeline.Run maps
	// it to RequestTimeoutNotification → 504.
	fwopenapi.MountRaw(d.OpenAPIRegistry, sc, fiber.MethodGet, "/slow",
		func(c fiber.Ctx) error {
			ms := defaultSlowSleepMillis
			if raw := c.Query("sleepMillis"); raw != "" {
				if n, err := strconv.Atoi(raw); err == nil && n >= 0 {
					ms = n
				}
			}
			appCtx := fwweb.AppContext(c)
			appCtx.SetParentIfAbsent(c)
			q := &appqa.SlowGadgetQuery{Sleep: time.Duration(ms) * time.Millisecond}
			result := pipeline.Dispatch(d.Pipeline, appCtx, q, &appqa.SlowGadgetHandler{})
			return fwweb.RespondFromResult(c, result, fiber.StatusOK)
		},
		fwopenapi.RawSpec{
			Summary:     "Sleep ?sleepMillis honoring the deadline → 504 under a low timeout",
			Description: "Under a low http.requestTimeoutSeconds the deadline fires first and pipeline.Run maps context.DeadlineExceeded to RequestTimeoutNotification (504).",
			Tags:        scTags, Public: true, Hidden: true,
			Parameters: []fwopenapi.Parameter{
				{In: fwopenapi.InQuery, Name: "sleepMillis", Description: "handler sleep in ms (default 3000)"},
			},
		})

	// The ECHOED VALUE of every type a rule may hand to AddNotification. Same
	// pipeline + RespondFromResult path as the 503 above; what this one proves is
	// not the status (SchemaViolationNotification is SemanticSchema → 400) but
	// the `value` field of each message — the answer to "which value did you
	// refuse?".
	fwopenapi.MountRaw(d.OpenAPIRegistry, sc, fiber.MethodGet, "/echo-values",
		func(c fiber.Ctx) error {
			appCtx := fwweb.AppContext(c)
			appCtx.SetParentIfAbsent(c)
			result := pipeline.Dispatch(d.Pipeline, appCtx,
				&appqa.EchoValuesQuery{}, &appqa.EchoValuesHandler{})
			return fwweb.RespondFromResult(c, result, fiber.StatusOK)
		},
		fwopenapi.RawSpec{
			Summary:     "Echo one notification per value type → 422",
			Description: "Emits one SchemaViolationNotification per flavour the AddNotification value variadic accepts — scalars, every POINTER kind (the optional-field shape), both value-object flavours, a self-rendering type, and a nil pointer. Each message's `value` must be the VALUE, never a memory address.",
			Tags:        scTags, Public: true, Hidden: true,
		})

	// Read-side option showcases. Each reuses the canonical Gadget list DTOs +
	// query; only the target view (and, for the last one, the openapi mount
	// channel) differs.

	// DeleteOnArchive — list over `gadgets_hot`. Archived gadgets are absent here
	// (dropped from the projection) but survive in the default `gadgets` list.
	hotH, hotSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindGadgetsRequest{},
		FindGadgetsResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery, appqa.FindGadgetsResult]{
			Reader: d.ViewReader, View: hotView,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/gadgets-hot",
		hotH, hotSpec,
		fwopenapi.Doc{
			Summary:     "List gadgets (DeleteOnArchive hot-tier view)",
			Description: "Paged read against the `gadgets_hot` Mongo view, which opts into DeleteOnArchive(): archiving a gadget DROPS it from this collection. Compare with GET /qa/gadgets, where the archived row is kept (hidden unless ?includeArchived=true).",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	// MaxLimit — list over `gadgets_capped` (MaxLimit 5). ?first>5 is rejected
	// with 400 LimitExceededNotification at read time.
	cappedH, cappedSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindGadgetsRequest{},
		FindGadgetsResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery, appqa.FindGadgetsResult]{
			Reader: d.ViewReader, View: cappedView,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/gadgets-capped",
		cappedH, cappedSpec,
		fwopenapi.Doc{
			Summary:     "List gadgets (MaxLimit(5) capped view)",
			Description: "Paged read against the `gadgets_capped` Mongo view, declared with .MaxLimit(5). A ?first greater than 5 is rejected with 400 LimitExceededNotification (per-view ceiling); the default `gadgets` view keeps the framework default of 100.",
			Tags:        []string{"QA Gadgets"},
		},
		fwopenapi.RequirePermission("gadgets:read"))

	// Second surface over the SAME default `gadgets` view, mounted through the
	// RAW openapi channel (MountRaw + a hidden RawSpec) rather than the
	// reflected one. It exists to prove the two mount channels are
	// interchangeable for a read: the wire payload is byte-identical to
	// GET /qa/gadgets — the same Request DTO, the same typed Response, the same
	// json wire names — only the spec registration differs.
	rawH := fwweb.QueryWithParams(d.Pipeline,
		FindGadgetsRequest{},
		FindGadgetsResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery, appqa.FindGadgetsResult]{
			Reader: d.ViewReader, View: defaultView,
		})
	fwopenapi.MountRaw(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/gadgets-raw",
		rawH,
		fwopenapi.RawSpec{
			Summary:     "List gadgets through the raw openapi mount channel",
			Description: "Paged read over the default `gadgets` view mounted via fwopenapi.MountRaw. The projection is the ordinary typed FindGadgetsResponse — the read side has a single wire authority, so the payload matches GET /qa/gadgets exactly.",
			Tags:        []string{"QA Gadgets"}, Public: true, Hidden: true,
		})
}
