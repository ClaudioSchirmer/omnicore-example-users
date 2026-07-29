//go:build qa

package main

import (
	"reflect"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"

	"github.com/gofiber/fiber/v3"
)

// AdminFeature exposes operator-driven retry routes for the framework's
// two side-channel failure registries: integration receivers (via the
// IntegrationRegistry) and cross-service upstream subscribers (via the
// UpstreamSubscribers slice). Mount-only feature — no domain, no
// repository, no view. Implements bootstrap.Feature only.
//
// Both routes sit behind RequirePermission("admin:retry") so a JWT
// without the claim cannot drive a retry storm. They live under the
// canonical admin tag in the OpenAPI surface so an operator browsing
// /docs sees them grouped together with any future framework-side
// admin endpoints (purge, replay, force-rebuild).
//
// The handlers read the registry / subscriber slice via closure at
// request time — by the time HTTP starts serving (after Phase
// Receivers + ConsumerPool.Start completed) both are fully populated.
type AdminFeature struct{}

// NewAdminFeature returns the singleton. The feature carries no
// state; the registries it walks are resolved from Deps at request
// time.
func NewAdminFeature() *AdminFeature { return &AdminFeature{} }

// retryResponse is the wire shape both admin routes emit on success.
// Aligns with the framework's existing canonical Response envelope:
// the operator parses one shape regardless of which surface they
// retried against.
type retryResponse struct {
	Retried int `json:"retried"`
}

// sweepResponse acknowledges a forced ledger sweep. The sweep reports per-row
// outcomes through the structured log and the ledger's own resolved_at — a
// count here would double-book what the table already records.
type sweepResponse struct {
	Swept bool `json:"swept"`
}

// Mount registers the two admin retry routes. RequirePermission gates
// each one independently; both share the same "admin:retry" string so
// the operator manages a single claim across both surfaces.
func (f *AdminFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	admin := app.Group("/admin/retries")

	projectionSpec := fwopenapi.RawSpec{
		Summary:     "Sweep the unified projection failure ledger now",
		Description: "Forces one immediate pass of the parked-retry sweep over omnicore_projection_failures — BOTH kinds: parked events replay from their stored payload, failed embed-segment ripples recompose from current state. The same sweep runs automatically on the mongo.parkedRetry cadence; this route exists for an operator who does not want to wait for the next tick.",
		Tags:        []string{"Admin"},
		Responses: map[int]fwopenapi.ResponseSpec{
			200: {
				Description: "Sweep completed; `swept` confirms the pass ran (per-row outcomes are in the structured log / the ledger's resolved_at).",
				Type:        reflect.TypeOf(sweepResponse{}),
			},
		},
	}
	fwopenapi.MountRaw(d.OpenAPIRegistry, admin, fiber.MethodPost, "/projection",
		func(c fiber.Ctx) error {
			ctx := c.RequestCtx()
			if d.SyncEngine != nil {
				if err := d.SyncEngine.RetryPendingProjectionFailures(ctx); err != nil {
					d.Logger.Warn("admin projection-ledger sweep failed", "err", err)
					return c.Status(fiber.StatusInternalServerError).JSON(sweepResponse{Swept: false})
				}
			}
			return c.Status(fiber.StatusOK).JSON(sweepResponse{Swept: true})
		},
		projectionSpec,
		fwopenapi.RequirePermission("admin:retry"))

	integrationSpec := fwopenapi.RawSpec{
		Summary:     "Retry pending integration failures",
		Description: "Walks every Receiver on the IntegrationRegistry and re-dispatches each pending row in omnicore_integration_failures. Successful re-dispatches mark the rows resolved; failed re-dispatches refresh the attempt counter.",
		Tags:        []string{"Admin"},
		Responses: map[int]fwopenapi.ResponseSpec{
			200: {
				Description: "Retry attempted; `retried` is the total events the framework re-dispatched across every receiver.",
				Type:        reflect.TypeOf(retryResponse{}),
			},
		},
	}
	fwopenapi.MountRaw(d.OpenAPIRegistry, admin, fiber.MethodPost, "/integration",
		func(c fiber.Ctx) error {
			ctx := c.RequestCtx()
			total := 0
			if d.IntegrationRegistry != nil {
				for _, r := range d.IntegrationRegistry.Receivers() {
					n, err := r.RetryPendingFailures(ctx, d.DB, d.Pipeline, d.Logger)
					if err != nil {
						d.Logger.Warn("admin retry integration failed",
							"sourceKey", r.SourceKey(),
							"eventKey", r.EventKey(),
							"err", err)
					}
					total += n
				}
			}
			return c.Status(fiber.StatusOK).JSON(retryResponse{Retried: total})
		},
		integrationSpec,
		fwopenapi.RequirePermission("admin:retry"))
}
