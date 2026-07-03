//go:build qa

package qafixtures

import (
	"strconv"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/httpclient"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"

	infraqa "github.com/ClaudioSchirmer/omnicore-example-users/infra/qafixtures"

	"github.com/gofiber/fiber/v3"
)

// breakerProbeExtra is how many calls beyond the failureThreshold the breaker
// showcase makes, guaranteeing at least one call lands after the circuit
// opened and thus returns the ErrCircuitOpen sentinel.
const breakerProbeExtra = 2

// breakerFailureThreshold mirrors the defaults-level circuitBreaker
// failureThreshold declared in microservice.qa.yaml (3). The showcase issues
// breakerFailureThreshold + breakerProbeExtra calls so the last ones observe
// the open circuit.
const breakerFailureThreshold = 3

// MountQaHttpShowcase registers the QA-only outbound httpclient-advanced
// showcase under /qa/showcase/httpclient. Each route drives the QaHttpShowcase
// adapter and returns the observed result. Like the canonical httpclient
// showcase, every route goes through the openapi channel (MountRaw, hidden)
// and none imports httpclient except to branch on the ErrCircuitOpen sentinel.
//
//	GET /qa/showcase/httpclient/retry?key=&failFor=  → {attempts, recovered}
//	GET /qa/showcase/httpclient/breaker              → {tripped, lastError}
//	GET /qa/showcase/httpclient/idempotency          → {idempotencyKey}
//	GET /qa/showcase/httpclient/xml?code=            → {echoed}
//	GET /qa/showcase/httpclient/headers              → {authorization, xApiKey, xExtra}
func MountQaHttpShowcase(app *fiber.App, showcase *infraqa.QaHttpShowcase, d bootstrap.Deps) {
	hc := app.Group("/qa/showcase/httpclient")
	tags := []string{"QA Showcase — HTTPClient"}

	// RETRY — a single Call recovers after the flaky upstream stops 503-ing.
	fwopenapi.MountRaw(d.OpenAPIRegistry, hc, fiber.MethodGet, "/retry",
		func(c fiber.Ctx) error {
			ctx := fwweb.AppContext(c)
			ctx.SetParent(c)
			key := c.Query("key")
			if key == "" {
				key = "retry-demo"
			}
			failFor := defaultFlakyFailFor
			if raw := c.Query("failFor"); raw != "" {
				if n, err := strconv.Atoi(raw); err == nil && n >= 0 {
					failFor = n
				}
			}
			attempts, err := showcase.Flaky(ctx, key, failFor)
			if err != nil {
				return fwweb.RespondWithSuccess(c, fiber.StatusOK, fiber.Map{
					"attempts": attempts, "recovered": false, "error": err.Error(),
				})
			}
			return fwweb.RespondWithSuccess(c, fiber.StatusOK, fiber.Map{
				"attempts": attempts, "recovered": true,
			})
		},
		fwopenapi.RawSpec{
			Summary:     "Retry backoff recovers a flaky upstream",
			Description: "Issues one Call against the flaky upstream (retryOn 503, maxAttempts 3). The framework replays the same GET until the upstream stops returning 503; `recovered:true` + the observed attempt count prove retry ran.",
			Tags:        tags, Public: true, Hidden: true,
			Parameters: []fwopenapi.Parameter{
				{In: fwopenapi.InQuery, Name: "key", Description: "flaky counter key (default retry-demo)"},
				{In: fwopenapi.InQuery, Name: "failFor", Description: "leading 503s before success (default 2)"},
			},
		})

	// CIRCUIT BREAKER — repeated failures trip the breaker; later calls fail
	// fast with the ErrCircuitOpen sentinel.
	fwopenapi.MountRaw(d.OpenAPIRegistry, hc, fiber.MethodGet, "/breaker",
		func(c fiber.Ctx) error {
			ctx := fwweb.AppContext(c)
			ctx.SetParent(c)
			tripped := false
			lastError := ""
			for i := 0; i < breakerFailureThreshold+breakerProbeExtra; i++ {
				err := showcase.TripBreaker(ctx)
				if err != nil {
					lastError = err.Error()
				}
				if httpclient.IsCircuitOpen(err) {
					tripped = true
					lastError = "circuit open"
				}
			}
			return fwweb.RespondWithSuccess(c, fiber.StatusOK, fiber.Map{
				"tripped": tripped, "lastError": lastError,
			})
		},
		fwopenapi.RawSpec{
			Summary:     "Circuit breaker opens under sustained failure",
			Description: "Calls the always-503 upstream failureThreshold+2 times. After the defaults-level failureThreshold consecutive failures the per-(service,endpoint) breaker opens and further calls return httpclient.ErrCircuitOpen without dialing — reported as `tripped:true, lastError:\"circuit open\"`.",
			Tags:        tags, Public: true, Hidden: true,
		})

	// IDEMPOTENCY — the client injects an X-Idempotency-Key the upstream echoes.
	fwopenapi.MountRaw(d.OpenAPIRegistry, hc, fiber.MethodGet, "/idempotency",
		func(c fiber.Ctx) error {
			ctx := fwweb.AppContext(c)
			ctx.SetParent(c)
			key, err := showcase.Idempotency(ctx)
			if err != nil {
				return respondBadGateway(c, "idempotency call failed", err)
			}
			return fwweb.RespondWithSuccess(c, fiber.StatusOK, fiber.Map{
				"idempotencyKey": key,
			})
		},
		fwopenapi.RawSpec{
			Summary:     "Idempotency key auto-injected on POST",
			Description: "POSTs to an endpoint declaring idempotency: { header: X-Idempotency-Key, source: ctx }. The framework generates a UUIDv7 and attaches it; the upstream echoes it back. A non-empty `idempotencyKey` proves the client injected it.",
			Tags:        tags, Public: true, Hidden: true,
		})

	// XML — the client serializes an XML request body.
	fwopenapi.MountRaw(d.OpenAPIRegistry, hc, fiber.MethodGet, "/xml",
		func(c fiber.Ctx) error {
			ctx := fwweb.AppContext(c)
			ctx.SetParent(c)
			code := c.Query("code")
			if code == "" {
				code = "GADGET-XML-1"
			}
			echoed, err := showcase.SendXML(ctx, code)
			if err != nil {
				return respondBadGateway(c, "xml call failed", err)
			}
			return fwweb.RespondWithSuccess(c, fiber.StatusOK, fiber.Map{
				"echoed": echoed,
			})
		},
		fwopenapi.RawSpec{
			Summary:     "XML request codec round trip",
			Description: "POSTs <gadget><code>..</code></gadget> to an endpoint declaring requestCodec: xml via a http:\"body,xml\" field. The upstream parses the XML and echoes the code, proving the client serialized XML on the wire.",
			Tags:        tags, Public: true, Hidden: true,
			Parameters: []fwopenapi.Parameter{
				{In: fwopenapi.InQuery, Name: "code", Description: "code to serialize (default GADGET-XML-1)"},
			},
		})

	// HEADERS — a static auth provider + a per-call WithExtraHeader.
	fwopenapi.MountRaw(d.OpenAPIRegistry, hc, fiber.MethodGet, "/headers",
		func(c fiber.Ctx) error {
			ctx := fwweb.AppContext(c)
			ctx.SetParent(c)
			extra := c.Query("extra")
			if extra == "" {
				extra = "per-call-extra"
			}
			resp, err := showcase.Headers(ctx, extra)
			if err != nil {
				return respondBadGateway(c, "headers call failed", err)
			}
			return fwweb.RespondWithSuccess(c, fiber.StatusOK, resp)
		},
		fwopenapi.RawSpec{
			Summary:     "Static auth provider + per-call WithExtraHeader",
			Description: "GETs an endpoint on a service bound to a bearer-static auth provider (Authorization) with a YAML static X-Api-Key; the call adds X-Extra via WithExtraHeader. The upstream echoes all three, proving the provider and the runtime header both landed.",
			Tags:        tags, Public: true, Hidden: true,
			Parameters: []fwopenapi.Parameter{
				{In: fwopenapi.InQuery, Name: "extra", Description: "value for the per-call X-Extra header"},
			},
		})
}

// respondBadGateway renders a 502 envelope for an outbound call failure,
// mirroring the canonical showcase's error handling for upstream errors.
func respondBadGateway(c fiber.Ctx, msg string, err error) error {
	return fwweb.RespondWithSuccess(c, fiber.StatusBadGateway, fiber.Map{
		"error":  msg,
		"detail": err.Error(),
	})
}
