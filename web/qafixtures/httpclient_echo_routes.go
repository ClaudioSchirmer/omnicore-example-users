//go:build qa

package qafixtures

import (
	"encoding/xml"
	"strconv"
	"sync"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"

	"github.com/gofiber/fiber/v3"
)

// defaultFlakyFailFor is the number of leading 503s /qa/echo/flaky returns for
// a key when the caller omits ?failFor. Two failures + a success on the third
// hit fits inside the flaky endpoint's maxAttempts: 3 retry budget.
const defaultFlakyFailFor = 2

// flakyState is the in-process per-key call counter behind /qa/echo/flaky. A
// single retrying Call replays the SAME request → the same key → the counter
// climbs across attempts until it passes failFor and the handler flips to 200.
// Guarded by mu because Fiber serves concurrently.
type flakyState struct {
	mu     sync.Mutex
	counts map[string]int
}

func newFlakyState() *flakyState { return &flakyState{counts: map[string]int{}} }

// hit increments and returns the call count for key.
func (s *flakyState) hit(key string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.counts[key]++
	return s.counts[key]
}

// MountQaEcho registers the QA-only upstream echo routes under /qa/echo. They
// are the producer side of the outbound httpclient-advanced showcase — the
// QaHttpShowcase adapter (infra/qafixtures) consumes them through the
// `qa-echo` / `qa-echo-auth` YAML services. Mirrors the canonical MountEcho:
// every route goes through fwopenapi.MountRaw with a hidden+public RawSpec so
// they register on Fiber (reachable at runtime, anonymous under auth) without
// polluting the rendered spec.
//
//	GET  /qa/echo/flaky?key=&failFor=  503 while count<=failFor, else 200 {attempts, ok}
//	GET  /qa/echo/always500            always 503 (drives the breaker)
//	POST /qa/echo/idempotency          echoes X-Idempotency-Key → {idempotencyKey}
//	POST /qa/echo/xml                  parses <gadget><code>..</code></gadget> → {code}
//	GET  /qa/echo/headers              echoes {authorization, xApiKey, xExtra}
func MountQaEcho(app *fiber.App, d bootstrap.Deps) {
	echo := app.Group("/qa/echo")
	hidden := fwopenapi.RawSpec{Hidden: true, Public: true, Tags: []string{"QA Echo"}}

	flaky := newFlakyState()

	// STATEFUL flaky endpoint: 503 for the first failFor hits of a key, then
	// 200. A retrying GET fails then recovers, proving retry backoff replayed
	// the same request.
	fwopenapi.MountRaw(d.OpenAPIRegistry, echo, fiber.MethodGet, "/flaky",
		func(c fiber.Ctx) error {
			key := c.Query("key")
			failFor := defaultFlakyFailFor
			if raw := c.Query("failFor"); raw != "" {
				if n, err := strconv.Atoi(raw); err == nil && n >= 0 {
					failFor = n
				}
			}
			count := flaky.hit(key)
			if count <= failFor {
				return c.Status(fiber.StatusServiceUnavailable).
					JSON(fiber.Map{"attempts": count, "ok": false})
			}
			return c.Status(fiber.StatusOK).
				JSON(fiber.Map{"attempts": count, "ok": true})
		}, hidden)

	// Always 503 — drives the circuit breaker toward open.
	fwopenapi.MountRaw(d.OpenAPIRegistry, echo, fiber.MethodGet, "/always500",
		func(c fiber.Ctx) error {
			return c.Status(fiber.StatusServiceUnavailable).
				JSON(fiber.Map{"ok": false})
		}, hidden)

	// Echo the received idempotency key so the consumer proves the client
	// attached it automatically (source: ctx).
	fwopenapi.MountRaw(d.OpenAPIRegistry, echo, fiber.MethodPost, "/idempotency",
		func(c fiber.Ctx) error {
			return c.JSON(fiber.Map{
				"idempotencyKey": string(c.Request().Header.Peek("X-Idempotency-Key")),
			})
		}, hidden)

	// Parse an XML body and return the parsed code as JSON, proving the client
	// serialized XML (requestCodec: xml + http:"body,xml").
	fwopenapi.MountRaw(d.OpenAPIRegistry, echo, fiber.MethodPost, "/xml",
		func(c fiber.Ctx) error {
			var payload struct {
				XMLName xml.Name `xml:"gadget"`
				Code    string   `xml:"code"`
			}
			if err := xml.Unmarshal(c.Body(), &payload); err != nil {
				return fiber.NewError(fiber.StatusBadRequest, "invalid xml body: "+err.Error())
			}
			return c.JSON(fiber.Map{"code": payload.Code})
		}, hidden)

	// Echo selected request headers back so the consumer proves the static
	// auth provider (Authorization + X-Api-Key) and the per-call
	// WithExtraHeader (X-Extra) all reached the upstream.
	fwopenapi.MountRaw(d.OpenAPIRegistry, echo, fiber.MethodGet, "/headers",
		func(c fiber.Ctx) error {
			return c.JSON(fiber.Map{
				"authorization": string(c.Request().Header.Peek("Authorization")),
				"xApiKey":       string(c.Request().Header.Peek("X-Api-Key")),
				"xExtra":        string(c.Request().Header.Peek("X-Extra")),
			})
		}, hidden)
}
