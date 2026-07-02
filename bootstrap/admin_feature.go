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

// Mount registers the two admin retry routes. RequirePermission gates
// each one independently; both share the same "admin:retry" string so
// the operator manages a single claim across both surfaces.
func (f *AdminFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	admin := app.Group("/admin/retries")

	upstreamSpec := fwopenapi.RawSpec{
		Summary:     "Retry pending upstream failures",
		Description: "Walks every UpstreamSubscriber and re-runs the recompose ripple for each pending failure row in omnicore_upstream_failures. Successful re-ripples mark the rows resolved; persistent failures keep accumulating attempt counts.",
		Tags:        []string{"Admin"},
		Responses: map[int]fwopenapi.ResponseSpec{
			200: {
				Description: "Retry attempted; `retried` is the total upstream_ids across every subscriber that the framework re-dispatched.",
				Type:        reflect.TypeOf(retryResponse{}),
			},
		},
	}
	fwopenapi.MountRaw(d.OpenAPIRegistry, admin, fiber.MethodPost, "/upstream",
		func(c fiber.Ctx) error {
			ctx := c.RequestCtx()
			total := 0
			for _, sub := range d.UpstreamSubscribers {
				if sub == nil {
					continue
				}
				n, err := sub.RetryPendingFailures(ctx)
				if err != nil {
					d.Logger.Warn("admin retry upstream failed",
						"err", err)
				}
				total += n
			}
			return c.Status(fiber.StatusOK).JSON(retryResponse{Retried: total})
		},
		upstreamSpec,
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
