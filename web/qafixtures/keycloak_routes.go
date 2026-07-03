//go:build qa

package qafixtures

import (
	"errors"

	fwweb "github.com/ClaudioSchirmer/omnicore/web"

	infraqa "github.com/ClaudioSchirmer/omnicore-example-users/infra/qafixtures"
	"github.com/gofiber/fiber/v3"
)

// keycloakRealm hits Keycloak's OIDC discovery endpoint. Anonymous; the
// framework caches the response per the YAML endpoint TTL (5m). Subsequent
// requests within the TTL never reach Keycloak — verify via the slog
// observation's `cacheStatus` field.
//
// Registered by MountShowcase under /showcase/keycloak/realm.
func keycloakRealm(kc *infraqa.KeycloakService) fiber.Handler {
	return func(c fiber.Ctx) error {
		ctx := fwweb.AppContext(c)
		ctx.SetParent(c)
		info, err := kc.GetRealmInfo(ctx)
		if err != nil {
			return respondWithError(c, fiber.StatusBadGateway, "keycloak realm fetch failed", err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, info)
	}
}

// keycloakAdminUser fetches a user from the Keycloak admin REST API.
// Exercises the oauth2-client-credentials provider end-to-end: the
// framework acquires a service-account token, caches it per-provider with
// single-flight, attaches it as `Authorization: Bearer ...`, and handles
// revocation on 401. The endpoint declares `acceptableStatus: [404]` so a
// missing user returns a clean 404 instead of leaking the upstream
// payload.
//
// Registered by MountShowcase under /showcase/keycloak/admin/:id.
func keycloakAdminUser(kc *infraqa.KeycloakService) fiber.Handler {
	return func(c fiber.Ctx) error {
		ctx := fwweb.AppContext(c)
		ctx.SetParent(c)
		user, err := kc.FetchUser(ctx, c.Params("id"))
		switch {
		case errors.Is(err, infraqa.ErrUserNotFound):
			return respondWithError(c, fiber.StatusNotFound, "user not found", err)
		case err != nil:
			return respondWithError(c, fiber.StatusBadGateway, "keycloak admin fetch failed", err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, user)
	}
}

// keycloakTenantWhoami exercises the credentials-exchange provider with
// requestFieldsFromCtx. The caller passes ?username=...&password=... in the
// query string (DEMO ONLY — production callers thread credentials from a
// vault or a session, never from URL params). The framework reads the
// values from AppContext at acquire time, hashes them into the per-identity
// token cache key, and caches the resulting bearer per (username,
// password) pair.
//
// Registered by MountShowcase under /showcase/keycloak/tenant/whoami.
func keycloakTenantWhoami(kc *infraqa.KeycloakService) fiber.Handler {
	return func(c fiber.Ctx) error {
		username := c.Query("username")
		password := c.Query("password")
		if username == "" || password == "" {
			return respondWithError(c, fiber.StatusBadRequest, "username and password query params are required (demo only)", nil)
		}
		ctx := fwweb.AppContext(c)
		ctx.SetParent(c)
		who, err := kc.WhoamiTenant(ctx, username, password)
		if err != nil {
			return respondWithError(c, fiber.StatusBadGateway, "keycloak tenant whoami failed", err)
		}
		return fwweb.RespondWithSuccess(c, fiber.StatusOK, who)
	}
}
