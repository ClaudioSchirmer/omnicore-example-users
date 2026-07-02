package web

import (
	"bytes"
	"strings"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/httpclient"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"

	appexternal "github.com/ClaudioSchirmer/omnicore-example-users/infra/external"

	"github.com/gofiber/fiber/v3"
)

// MountShowcase registers every framework-showcase route under /showcase/*.
// Split by upstream / feature catalog so each consumer is easy to find:
//
//	/showcase/keycloak/*    → exercise outbound auth providers (anonymous
//	                          cache, oauth2-client-credentials,
//	                          credentials-exchange) against the local
//	                          Keycloak fixture.
//	/showcase/httpclient/*  → exercise the outbound features that need an
//	                          in-process upstream (streaming surfaces,
//	                          HMAC signing, CallConfig overrides,
//	                          InlineAuth) against the /echo/* routes
//	                          registered by MountEcho.
//
// The /echo/* routes themselves are mounted by MountEcho — kept at the
// root (not nested under /showcase) because they are the upstream of the
// demos, not the demos themselves. ShowcaseFeature.Mount calls both
// MountShowcase and MountEcho.
//
// None of these handlers imports omnicore/infra/httpclient — each
// delegates to a vendor service struct in infra/external/. That keeps the
// canonical consumer pattern visible: handlers depend on a typed
// adapter; only the adapter touches the framework's outbound surface.
func MountShowcase(app *fiber.App, kc *appexternal.KeycloakService, echo *appexternal.EchoService, d bootstrap.Deps) {
	showcase := app.Group("/showcase")

	// Showcase routes are framework demos — vendor-specific request /
	// response shapes (Keycloak's OIDC discovery, /echo/*'s observation
	// reports). They register on Fiber so the runtime stays exercisable
	// but ship as Hidden: true so the rendered spec only advertises the
	// canonical (Auto), the manual showcase, and the framework-injected
	// surface (/health, /openapi.json, /docs). Operators that want to
	// surface the demos override the registration in their own service
	// rather than carry framework demos in the production spec by default.
	// Public: true is paired with Hidden so the under-the-hood routing
	// stays anonymous under auth.mode=jwt (no bearer required to hit
	// them in the sandbox).

	keycloakTags := []string{"Showcase — Keycloak"}
	httpclientTags := []string{"Showcase — HTTPClient"}

	kcGroup := showcase.Group("/keycloak")
	fwopenapi.MountRaw(d.OpenAPIRegistry, kcGroup, fiber.MethodGet, "/realm",
		keycloakRealm(kc),
		fwopenapi.RawSpec{
			Summary:     "Keycloak OIDC discovery (cached)",
			Description: "Calls Keycloak's OIDC discovery endpoint anonymously through the `keycloak-public` service. The response is cached per the YAML TTL (5m); successive calls return `cacheStatus=hit` in the slog log without round-tripping to Keycloak.",
			Tags:        keycloakTags, Public: true, Hidden: true,
		})
	fwopenapi.MountRaw(d.OpenAPIRegistry, kcGroup, fiber.MethodGet, "/admin/:id",
		keycloakAdminUser(kc),
		fwopenapi.RawSpec{
			Summary:     "Keycloak admin user fetch via oauth2-client-credentials",
			Description: "Fetches a Keycloak admin user through the `keycloak-admin` service. The `oauth2-client-credentials` provider acquires and caches the service-account bearer; 401 from the IdP triggers re-acquire via `revocationOnUnauthorized`. Returns 404 when the user is absent (path declared via `acceptableStatus: [404]`).",
			Tags:        keycloakTags, Public: true, Hidden: true,
			Parameters: []fwopenapi.Parameter{fwopenapi.PathParam("id", "Keycloak user UUID")},
		})
	fwopenapi.MountRaw(d.OpenAPIRegistry, kcGroup, fiber.MethodGet, "/tenant/whoami",
		keycloakTenantWhoami(kc),
		fwopenapi.RawSpec{
			Summary:     "Keycloak per-tenant whoami via credentials-exchange",
			Description: "Calls Keycloak's userinfo endpoint via the `keycloak-tenant` service. The `credentials-exchange` provider posts a per-tenant username/password (threaded via query string for the demo only) as a `password` grant; the resulting bearer is cached per-identity (SHA-256 of the resolved values).",
			Tags:        keycloakTags, Public: true, Hidden: true,
			Parameters: []fwopenapi.Parameter{
				{In: fwopenapi.InQuery, Name: "username", Description: "demo only — production threads from a vault", Required: true},
				{In: fwopenapi.InQuery, Name: "password", Description: "demo only — production threads from a vault", Required: true},
			},
		})

	hc := showcase.Group("/httpclient")
	fwopenapi.MountRaw(d.OpenAPIRegistry, hc, fiber.MethodGet, "/download-stream/:size",
		showcaseDownloadStream(echo),
		fwopenapi.RawSpec{
			Summary:     "Stream N bytes via httpclient StreamResponse",
			Description: "Streams `:size` bytes from the in-process `/echo/stream/:size` upstream as a `StreamResponse`. The framework hands the open body to the caller without buffering — the handler copies it through an `io.Reader`. Status, headers, and ContentLength surface in slog; the stream body itself is not captured.",
			Tags:        httpclientTags, Public: true, Hidden: true,
			Parameters: []fwopenapi.Parameter{fwopenapi.PathParam("size", "Byte count (max 16 MiB)")},
		})
	fwopenapi.MountRaw(d.OpenAPIRegistry, hc, fiber.MethodPost, "/upload-stream",
		showcaseUploadStream(echo),
		fwopenapi.RawSpec{
			Summary:     "Stream request body via http:\"body,stream\"",
			Description: "Pipes the incoming Fiber request body to `/echo/upload` via the framework's `http:\"body,stream\"` tag. Retry is forced to 1 attempt at runtime (the `io.Reader` is one-shot); the logging middleware skips request body capture.",
			Tags:        httpclientTags, Public: true, Hidden: true,
		})
	fwopenapi.MountRaw(d.OpenAPIRegistry, hc, fiber.MethodPost, "/multipart",
		showcaseMultipart(echo),
		fwopenapi.RawSpec{
			Summary:     "Multipart upload via http:\"body,multipart\"",
			Description: "Synthesizes a multipart payload (one text field + one in-memory file) and posts it to `/echo/multipart` via the framework's `http:\"body,multipart\"` tag. The body streams through an `io.Pipe` so file content is never fully buffered.",
			Tags:        httpclientTags, Public: true, Hidden: true,
		})
	fwopenapi.MountRaw(d.OpenAPIRegistry, hc, fiber.MethodGet, "/sse",
		showcaseSSE(echo),
		fwopenapi.RawSpec{
			Summary:     "Server-Sent Events via httpclient SSEResponse",
			Description: "Opens an SSE stream to `/echo/sse`, drains every event the framework's WHATWG EventSource parser dispatches, and returns them as a JSON array. The framework spawns the parser goroutine; the handler drains the channel to EOF before responding.",
			Tags:        httpclientTags, Public: true, Hidden: true,
		})
	fwopenapi.MountRaw(d.OpenAPIRegistry, hc, fiber.MethodPost, "/signed",
		showcaseSigned(echo),
		fwopenapi.RawSpec{
			Summary:     "HMAC-signed round trip",
			Description: "Posts a JSON payload via the `echo-signed` service, which declares an HMAC signing block. The framework injects `X-Date`, `X-Content-SHA256`, `X-Signature`, and `X-Key-Id` before dialing; the upstream echoes them back so the response surfaces the headers it observed.",
			Tags:        httpclientTags, Public: true, Hidden: true,
		})
	fwopenapi.MountRaw(d.OpenAPIRegistry, hc, fiber.MethodPost, "/with-config-override",
		showcaseWithConfigOverride(echo),
		fwopenapi.RawSpec{
			Summary:     "CallConfig.Method + CallConfig.Path runtime override",
			Description: "Exercises `CallConfig.Method` + `CallConfig.Path` runtime override. The YAML declares the endpoint as POST /echo/upload; the handler re-specifies method and path through `CallConfig` to prove the runtime override surface works without breaking the dispatch.",
			Tags:        httpclientTags, Public: true, Hidden: true,
		})
	fwopenapi.MountRaw(d.OpenAPIRegistry, hc, fiber.MethodPost, "/inline-bearer",
		showcaseInlineBearer(echo),
		fwopenapi.RawSpec{
			Summary:     "CallConfig.InlineAuth.Bearer runtime credential",
			Description: "Exercises `CallConfig.InlineAuth.Bearer` — per-call credentials that do not need a YAML auth provider. The upstream echoes the `Authorization` header back so the response surfaces what the framework attached. Pass `?token=...` to override the default demo token.",
			Tags:        httpclientTags, Public: true, Hidden: true,
			Parameters: []fwopenapi.Parameter{
				{In: fwopenapi.InQuery, Name: "token", Description: "Overrides the demo's default token"},
			},
		})
}

// showcaseDownloadStream fetches `:size` bytes from /echo/stream/:size
// as a StreamResponse, copies them into a buffer, and replies with the
// observed byte count plus the first bytes of the body. The framework
// hands the open response body to the caller without buffering, and the
// logging middleware does not capture the stream body (only status,
// headers, ContentLength surface in slog).
func showcaseDownloadStream(echo *appexternal.EchoService) fiber.Handler {
	return func(c fiber.Ctx) error {
		ctx := fwweb.AppContext(c)
		ctx.SetParent(c)
		n, sample, err := echo.DownloadStream(ctx, c.Params("size"))
		if err != nil {
			return respondWithError(c, fiber.StatusBadGateway, "download stream failed", err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, fiber.Map{
			"bytes":  n,
			"sample": sample,
		})
	}
}

// showcaseUploadStream pipes the incoming Fiber request body to
// /echo/upload via the framework's http:"body,stream" tag and returns
// the upstream's observed byte count. Retry is disabled at runtime (the
// io.Reader is one-shot) and the logging middleware does not capture
// the request body.
func showcaseUploadStream(echo *appexternal.EchoService) fiber.Handler {
	return func(c fiber.Ctx) error {
		ctx := fwweb.AppContext(c)
		ctx.SetParent(c)
		mime := string(c.Request().Header.ContentType())
		if mime == "" {
			mime = "application/octet-stream"
		}
		resp, err := echo.UploadStream(ctx, bytes.NewReader(c.Body()), mime)
		if err != nil {
			return respondWithError(c, fiber.StatusBadGateway, "upload stream failed", err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, resp)
	}
}

// showcaseMultipart synthesizes a multipart body with one text field
// and one in-memory file derived from the request body (or a default
// placeholder), then POSTs it via the framework's
// http:"body,multipart" tag. The body streams through an io.Pipe so
// file content is never fully buffered. Returns the upstream's parsed
// structure.
func showcaseMultipart(echo *appexternal.EchoService) fiber.Handler {
	return func(c fiber.Ctx) error {
		ctx := fwweb.AppContext(c)
		ctx.SetParent(c)
		payload := c.Body()
		if len(payload) == 0 {
			payload = []byte("PDF-PLACEHOLDER")
		}
		resp, err := echo.UploadMultipart(ctx,
			[]httpclient.MultipartField{{Name: "category", Value: "id-proof"}},
			[]httpclient.MultipartFile{{
				Name:     "file",
				Filename: "passport.pdf",
				MimeType: "application/pdf",
				Content:  bytes.NewReader(payload),
			}},
		)
		if err != nil {
			return respondWithError(c, fiber.StatusBadGateway, "multipart upload failed", err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, resp)
	}
}

// showcaseSSE opens an SSE stream to /echo/sse, drains all events the
// parser dispatches, and returns them as a JSON array. The framework
// spawns a goroutine that parses the WHATWG EventSource stream and
// emits SSEvent values; the caller MUST Close the response.
// Demonstrates id / event / data / retry parsing.
func showcaseSSE(echo *appexternal.EchoService) fiber.Handler {
	return func(c fiber.Ctx) error {
		ctx := fwweb.AppContext(c)
		ctx.SetParent(c)
		events, err := echo.SubscribeEvents(ctx)
		if err != nil {
			return respondWithError(c, fiber.StatusBadGateway, "sse subscription failed", err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, fiber.Map{
			"count":  len(events),
			"events": events,
		})
	}
}

// showcaseSigned POSTs a JSON payload via the echo-signed service which
// declares an HMAC signing block. The framework injects X-Date,
// X-Content-SHA256, X-Signature, and X-Key-Id before dialing; the
// upstream echoes them back. The QA suite asserts each header is
// populated, proving HMAC signing executed end to end.
func showcaseSigned(echo *appexternal.EchoService) fiber.Handler {
	return func(c fiber.Ctx) error {
		ctx := fwweb.AppContext(c)
		ctx.SetParent(c)
		payload := map[string]any{
			"hello": "signed-world",
			"size":  len(c.Body()),
		}
		resp, err := echo.SignedRoundTrip(ctx, payload)
		if err != nil {
			return respondWithError(c, fiber.StatusBadGateway, "signed round-trip failed", err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, resp)
	}
}

// showcaseWithConfigOverride proves CallConfig.Method and CallConfig.Path
// override the YAML at call time. The YAML declares echo.uploadStream as
// POST /echo/upload (no streaming flags). The handler re-specifies method
// and path through CallConfig — the call still lands on /echo/upload, but
// the framework's binding accepts the override and forwards a JSON body
// instead of streaming. Returns the upstream's byte count.
func showcaseWithConfigOverride(echo *appexternal.EchoService) fiber.Handler {
	return func(c fiber.Ctx) error {
		ctx := fwweb.AppContext(c)
		ctx.SetParent(c)
		body := string(c.Body())
		if strings.TrimSpace(body) == "" {
			body = "default-payload"
		}
		resp, err := echo.WithConfigOverride(ctx, body)
		if err != nil {
			return respondWithError(c, fiber.StatusBadGateway, "with-config override failed", err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, resp)
	}
}

// showcaseInlineBearer exercises CallConfig.InlineAuth.Bearer. The
// caller may supply ?token=... to override the demo's default token;
// the framework attaches Authorization: Bearer <token> to the request.
// The upstream echoes the Authorization header back so the QA suite can
// verify the framework propagated it. Demonstrates per-customer
// credentials supplied at call time instead of via a YAML auth provider.
func showcaseInlineBearer(echo *appexternal.EchoService) fiber.Handler {
	return func(c fiber.Ctx) error {
		ctx := fwweb.AppContext(c)
		ctx.SetParent(c)
		token := c.Query("token")
		resp, err := echo.InlineBearerRoundTrip(ctx, token, "inline-auth-demo")
		if err != nil {
			return respondWithError(c, fiber.StatusBadGateway, "inline-bearer round-trip failed", err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, resp)
	}
}
