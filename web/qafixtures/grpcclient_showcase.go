//go:build qa

package qafixtures

import (
	"errors"

	"connectrpc.com/connect"
	"github.com/gofiber/fiber/v3"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"

	infraqa "github.com/ClaudioSchirmer/omnicore-example-users/infra/qafixtures"
)

// MountGrpcClientShowcase exercises the outbound gRPC toolbox end to end by
// calling THIS service's own UsersService over the loopback gRPC listener —
// the same pattern the httpclient showcases use with /echo/*. The routes
// are thin REST shells: the outbound consumption lives in the
// infraqa.UsersGRPCService adapter (web never imports the client — the same
// rule the httpclient showcase honors via EchoService). A nil adapter
// (grpcClient yaml block absent) answers 503 so the QA fails loudly.
//
//	GET /qa/showcase/grpcclient/users/:id   → GetUser via gRPC
//	GET /qa/showcase/grpcclient/users       → ListUsers via gRPC (?userName=)
func MountGrpcClientShowcase(app *fiber.App, users *infraqa.UsersGRPCService, qa *infraqa.QAGRPCService, d bootstrap.Deps) {
	fwopenapi.MountRaw(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/showcase/grpcclient/users/:id", func(c fiber.Ctx) error {
		if users == nil {
			return c.Status(fiber.StatusServiceUnavailable).JSON(fiber.Map{"error": "grpcClient yaml block absent"})
		}
		appCtx := fwweb.AppContext(c)
		appCtx.SetParentIfAbsent(c)
		res, err := users.GetUser(appCtx, c.Params("id"), fiber.Query[bool](c, "includeArchived"))
		if err != nil {
			return respondGrpcClientError(c, err)
		}
		return c.JSON(fiber.Map{
			"via":      "grpcclient",
			"id":       res.GetId(),
			"name":     res.GetName(),
			"userName": res.GetUserName(),
		})
	}, fwopenapi.RawSpec{
		Summary:     "grpcclient showcase — GetUser via the outbound gRPC toolbox",
		Description: "Calls THIS service's own UsersService over the loopback gRPC listener through the infraqa.UsersGRPCService adapter (Deps.GRPCClient, `grpcClient.services.self-users`), running the full client chain: correlation, idempotency key, retry, breaker, per-service deadline.",
		Tags:        []string{"QA Showcase"}, Public: true, Hidden: true,
	})

	fwopenapi.MountRaw(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/showcase/grpcclient/users", func(c fiber.Ctx) error {
		if users == nil {
			return c.Status(fiber.StatusServiceUnavailable).JSON(fiber.Map{"error": "grpcClient yaml block absent"})
		}
		appCtx := fwweb.AppContext(c)
		appCtx.SetParentIfAbsent(c)
		res, err := users.ListUsersByUserName(appCtx, fiber.Query[string](c, "userName"))
		if err != nil {
			return respondGrpcClientError(c, err)
		}
		names := make([]string, 0, len(res.GetItems()))
		for _, u := range res.GetItems() {
			names = append(names, u.GetUserName())
		}
		return c.JSON(fiber.Map{"via": "grpcclient", "total": res.GetTotal(), "userNames": names})
	}, fwopenapi.RawSpec{
		Summary:     "grpcclient showcase — ListUsers via the outbound gRPC toolbox",
		Description: "The list sibling of the GetUser showcase: `?userName=` becomes the typed equality filter (shared omnicore.v1 components) on the proto request, composed inside the adapter.",
		Tags:        []string{"QA Showcase"}, Public: true, Hidden: true,
	})
}

// MountGrpcClientResilience exposes the deterministic client-chain checks:
// /flaky drives retry+idempotency (server-counted attempts + distinct
// keys), /boom feeds the aggressive breaker until it opens.
func MountGrpcClientResilience(app *fiber.App, qa *infraqa.QAGRPCService, d bootstrap.Deps) {
	fwopenapi.MountRaw(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/showcase/grpcclient/flaky", func(c fiber.Ctx) error {
		if qa == nil {
			return c.Status(fiber.StatusServiceUnavailable).JSON(fiber.Map{"error": "grpcClient yaml block absent"})
		}
		appCtx := fwweb.AppContext(c)
		appCtx.SetParentIfAbsent(c)
		res, err := qa.FlakyEcho(appCtx, fiber.Query[string](c, "key"), int32(fiber.Query[int](c, "fail")))
		if err != nil {
			return respondGrpcClientError(c, err)
		}
		return c.JSON(fiber.Map{"attempts": res.GetAttempts(), "distinctKeys": res.GetDistinctKeys()})
	}, fwopenapi.RawSpec{
		Summary: "grpcclient resilience — deterministic retry/idempotency probe",
		Tags:    []string{"QA Showcase"}, Public: true, Hidden: true,
	})

	fwopenapi.MountRaw(d.OpenAPIRegistry, app, fiber.MethodGet, "/qa/showcase/grpcclient/boom", func(c fiber.Ctx) error {
		if qa == nil {
			return c.Status(fiber.StatusServiceUnavailable).JSON(fiber.Map{"error": "grpcClient yaml block absent"})
		}
		appCtx := fwweb.AppContext(c)
		appCtx.SetParentIfAbsent(c)
		if err := qa.Boom(appCtx); err != nil {
			return respondGrpcClientError(c, err)
		}
		return c.JSON(fiber.Map{"unexpected": "boom succeeded"})
	}, fwopenapi.RawSpec{
		Summary: "grpcclient resilience — breaker feeder (always fails upstream)",
		Tags:    []string{"QA Showcase"}, Public: true, Hidden: true,
	})
}

// respondGrpcClientError maps the upstream connect error onto the showcase
// response: NOT_FOUND stays 404, everything else surfaces as 502 with the
// code — enough for the QA suite to assert the client-side classification.
func respondGrpcClientError(c fiber.Ctx, err error) error {
	var cerr *connect.Error
	if errors.As(err, &cerr) {
		status := fiber.StatusBadGateway
		if cerr.Code() == connect.CodeNotFound {
			status = fiber.StatusNotFound
		}
		return c.Status(status).JSON(fiber.Map{"code": cerr.Code().String(), "error": cerr.Message()})
	}
	return c.Status(fiber.StatusBadGateway).JSON(fiber.Map{"error": err.Error()})
}
