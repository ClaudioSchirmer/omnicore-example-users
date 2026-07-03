//go:build qa

package qafixtures

import (
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwcache "github.com/ClaudioSchirmer/omnicore/infra/cache"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"

	"github.com/gofiber/fiber/v3"
)

// MountCacheShowcase exposes a minimal CRUD over the framework's cache
// subsystem so qa/cache.sh — and any operator-side smoke test — can drive
// Deps.Cache and Deps.SharedCache end to end without spinning a separate
// domain handler.
//
// Three groups of routes are mounted under /showcase/cache:
//
//	GET    /showcase/cache/info              — reports which Cache deps the
//	                                            framework resolved at boot
//	POST   /showcase/cache/private/:key      — cache.SetJSON against Deps.Cache
//	GET    /showcase/cache/private/:key      — cache.GetJSON against Deps.Cache
//	DELETE /showcase/cache/private/:key      — cache.Delete against Deps.Cache
//	POST   /showcase/cache/shared/:key       — cache.SetJSON against Deps.SharedCache
//	GET    /showcase/cache/shared/:key       — cache.GetJSON against Deps.SharedCache
//	DELETE /showcase/cache/shared/:key       — cache.Delete against Deps.SharedCache
//
// The shared routes return 503 (Service Unavailable) when Deps.SharedCache
// is nil — operators that don't declare `cache.shared:` in YAML get a
// clear signal at the call site rather than a nil panic. Symmetric on the
// private side: 503 when Deps.Cache is nil (operator omitted `cache:`).
//
// Body shape on POST: {"value": "<string>", "ttl_seconds": <int>}. The
// handler round-trips this struct as the cached value via cache.SetJSON
// /cache.GetJSON, so the on-wire response of GET carries the exact same
// shape. Operators inspecting Redis via `redis-cli GET <prefix>:<key>`
// observe the encoded JSON value verbatim.
//
// All routes are marked Hidden (excluded from the OpenAPI spec) AND
// Public (no AuthMiddleware) — they are showcase / QA fixtures, not
// production surface. Operators that want them documented override the
// registration in their own service.
func MountCacheShowcase(app *fiber.App, d bootstrap.Deps) {
	g := app.Group("/showcase/cache")

	fwopenapi.MountRaw(d.OpenAPIRegistry, g, fiber.MethodGet, "/info",
		cacheInfoHandler(d),
		fwopenapi.RawSpec{Summary: "Cache subsystem info", Tags: []string{"Showcase"}, Hidden: true, Public: true})

	// Private cache routes (Deps.Cache).
	fwopenapi.MountRaw(d.OpenAPIRegistry, g, fiber.MethodPost, "/private/:key",
		cacheSetHandler(d, scopePrivate),
		fwopenapi.RawSpec{Summary: "Set private cache entry", Tags: []string{"Showcase"}, Hidden: true, Public: true})
	fwopenapi.MountRaw(d.OpenAPIRegistry, g, fiber.MethodGet, "/private/:key",
		cacheGetHandler(d, scopePrivate),
		fwopenapi.RawSpec{Summary: "Get private cache entry", Tags: []string{"Showcase"}, Hidden: true, Public: true})
	fwopenapi.MountRaw(d.OpenAPIRegistry, g, fiber.MethodDelete, "/private/:key",
		cacheDeleteHandler(d, scopePrivate),
		fwopenapi.RawSpec{Summary: "Delete private cache entry", Tags: []string{"Showcase"}, Hidden: true, Public: true})

	// Shared cache routes (Deps.SharedCache).
	fwopenapi.MountRaw(d.OpenAPIRegistry, g, fiber.MethodPost, "/shared/:key",
		cacheSetHandler(d, scopeShared),
		fwopenapi.RawSpec{Summary: "Set shared cache entry", Tags: []string{"Showcase"}, Hidden: true, Public: true})
	fwopenapi.MountRaw(d.OpenAPIRegistry, g, fiber.MethodGet, "/shared/:key",
		cacheGetHandler(d, scopeShared),
		fwopenapi.RawSpec{Summary: "Get shared cache entry", Tags: []string{"Showcase"}, Hidden: true, Public: true})
	fwopenapi.MountRaw(d.OpenAPIRegistry, g, fiber.MethodDelete, "/shared/:key",
		cacheDeleteHandler(d, scopeShared),
		fwopenapi.RawSpec{Summary: "Delete shared cache entry", Tags: []string{"Showcase"}, Hidden: true, Public: true})
}

// cacheScope discriminates the two Deps slots the showcase routes target.
type cacheScope int

const (
	scopePrivate cacheScope = iota
	scopeShared
)

// resolveCache returns the Deps slot matching the scope.
func resolveCache(d bootstrap.Deps, s cacheScope) fwcache.Cache {
	if s == scopeShared {
		return d.SharedCache
	}
	return d.Cache
}

// cacheValue is the on-wire shape the showcase round-trips through
// cache.SetJSON / cache.GetJSON. Mirrors the body POST clients send.
type cacheValue struct {
	Value      string `json:"value"`
	TTLSeconds int    `json:"ttl_seconds"`
}

// cacheSetRequest is the POST body. Matches cacheValue field-for-field
// so the handler stores the request verbatim and a GET returns the same
// shape.
type cacheSetRequest struct {
	Value      string `json:"value"`
	TTLSeconds int    `json:"ttl_seconds"`
}

// cacheInfoResponse reports which Deps slots resolved at boot. Operators
// use this to confirm the YAML cache: block reached the runtime.
type cacheInfoResponse struct {
	Private cacheSlotInfo `json:"private"`
	Shared  cacheSlotInfo `json:"shared"`
}

type cacheSlotInfo struct {
	Configured bool `json:"configured"`
}

// cacheInfoHandler is a sanity surface: returns whether private / shared
// caches are wired so qa/cache.sh can branch its assertions.
func cacheInfoHandler(d bootstrap.Deps) fiber.Handler {
	return func(c fiber.Ctx) error {
		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, cacheInfoResponse{
			Private: cacheSlotInfo{Configured: d.Cache != nil},
			Shared:  cacheSlotInfo{Configured: d.SharedCache != nil},
		})
	}
}

// cacheSetHandler stores the request body's value under the path key with
// the requested TTL. Honors ttl_seconds == 0 as "no expiration" per the
// framework's Cache contract.
func cacheSetHandler(d bootstrap.Deps, s cacheScope) fiber.Handler {
	return func(c fiber.Ctx) error {
		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)
		store := resolveCache(d, s)
		if store == nil {
			return respondCacheUnavailable(c, s)
		}
		key := c.Params("key")
		if key == "" {
			return respondCacheBadKey(c)
		}
		var req cacheSetRequest
		if err := json.Unmarshal(c.Body(), &req); err != nil {
			return respondCacheBadBody(c, err)
		}
		ttl := time.Duration(req.TTLSeconds) * time.Second
		if err := fwcache.SetJSON(appCtx, store, key, cacheValue{Value: req.Value, TTLSeconds: req.TTLSeconds}, ttl); err != nil {
			return respondCacheError(c, err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, fiber.Map{"key": key, "scope": scopeName(s)})
	}
}

// cacheGetHandler retrieves the value under key. Miss returns 404.
func cacheGetHandler(d bootstrap.Deps, s cacheScope) fiber.Handler {
	return func(c fiber.Ctx) error {
		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)
		store := resolveCache(d, s)
		if store == nil {
			return respondCacheUnavailable(c, s)
		}
		key := c.Params("key")
		if key == "" {
			return respondCacheBadKey(c)
		}
		val, ok, err := fwcache.GetJSON[cacheValue](appCtx, store, key)
		if err != nil {
			return respondCacheError(c, err)
		}
		if !ok {
			return c.Status(fiber.StatusNotFound).JSON(fiber.Map{
				"success": false,
				"status":  fiber.StatusNotFound,
				"errors": []fiber.Map{{
					"context": "Cache",
					"messages": []fiber.Map{{
						"notificationKey": "RecordNotFoundNotification",
						"field":           "key",
						"value":           key,
						"message":         "Cache entry not found.",
					}},
				}},
			})
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, fiber.Map{
			"key":         key,
			"scope":       scopeName(s),
			"value":       val.Value,
			"ttl_seconds": val.TTLSeconds,
		})
	}
}

// cacheDeleteHandler removes the entry under key. Idempotent (missing
// keys are not an error).
func cacheDeleteHandler(d bootstrap.Deps, s cacheScope) fiber.Handler {
	return func(c fiber.Ctx) error {
		appCtx := fwweb.AppContext(c)
		appCtx.SetParent(c)
		store := resolveCache(d, s)
		if store == nil {
			return respondCacheUnavailable(c, s)
		}
		key := c.Params("key")
		if key == "" {
			return respondCacheBadKey(c)
		}
		if err := store.Delete(appCtx, key); err != nil {
			return respondCacheError(c, err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, fiber.Map{"key": key, "scope": scopeName(s)})
	}
}

func scopeName(s cacheScope) string {
	if s == scopeShared {
		return "shared"
	}
	return "private"
}

func respondCacheUnavailable(c fiber.Ctx, s cacheScope) error {
	scope := scopeName(s)
	return c.Status(fiber.StatusServiceUnavailable).JSON(fiber.Map{
		"success": false,
		"status":  fiber.StatusServiceUnavailable,
		"errors": []fiber.Map{{
			"context": "Cache",
			"messages": []fiber.Map{{
				"notificationKey": "ServiceUnavailableNotification",
				"field":           "scope",
				"value":           scope,
				"message":         "The " + scope + " cache is not configured. Declare `cache" + sharedSuffix(s) + ":` in microservice.<profile>.yaml to enable it.",
			}},
		}},
	})
}

func sharedSuffix(s cacheScope) string {
	if s == scopeShared {
		return ".shared"
	}
	return ""
}

func respondCacheBadKey(c fiber.Ctx) error {
	return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
		"success": false,
		"status":  fiber.StatusBadRequest,
		"errors": []fiber.Map{{
			"context": "Cache",
			"messages": []fiber.Map{{
				"notificationKey": "RequiredFieldNotification",
				"field":           "key",
				"message":         "Key path segment is required.",
			}},
		}},
	})
}

func respondCacheBadBody(c fiber.Ctx, err error) error {
	return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
		"success": false,
		"status":  fiber.StatusBadRequest,
		"errors": []fiber.Map{{
			"context": "Cache",
			"messages": []fiber.Map{{
				"notificationKey": "SchemaViolationNotification",
				"field":           "body",
				"message":         "Invalid JSON body: " + err.Error(),
			}},
		}},
	})
}

func respondCacheError(c fiber.Ctx, err error) error {
	// failOpen Redis backends never return an error to here — the
	// adapter swallows transport failures and reports a miss. failClosed
	// surfaces the error verbatim; the showcase reports the underlying
	// reason so qa/cache.sh can assert on it.
	status := fiber.StatusInternalServerError
	msg := "Cache backend error: " + err.Error()
	if errors.Is(err, fwcache.ErrInvalidTTL) {
		status = fiber.StatusBadRequest
		msg = "Invalid TTL (must be non-negative): " + err.Error()
	}
	return c.Status(status).JSON(fiber.Map{
		"success": false,
		"status":  status,
		"errors": []fiber.Map{{
			"context": "Cache",
			"messages": []fiber.Map{{
				"notificationKey": "CacheBackendErrorNotification",
				"message":         msg,
			}},
		}},
	})
}

// Anchor unused import lint — strings is used by future cases (varyOn
// inspection, prefix listing). Keep the import here so the file compiles
// when those land without re-importing then.
var _ = strings.TrimSpace
