//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"

	"github.com/gofiber/fiber/v3"
)

// WhoamiResponse is the documented JSON shape of GET /whoami. Declared
// at package scope so the openapi spec assembler can name it via $ref
// in components/schemas; the handler still emits a free-form
// fiber.Map at runtime so a future addition (issuer, audience, ...)
// does not require touching this struct first.
type WhoamiResponse struct {
	Subject       string `json:"subject"          example:"alice-uuid-abc123"`
	Issuer        string `json:"issuer,omitempty" example:"http://localhost:8088/realms/omnicore-test"`
	Authenticated bool   `json:"authenticated"    example:"true"`
}

// MountWhoami registers GET /whoami at the root via openapi.MountRaw —
// the canonical demo of consuming AppContext.Identity() directly from
// a custom Fiber handler. RawSpec carries the documentation: tag,
// summary, declared 200 shape pointing at WhoamiResponse.
//
// Auth behavior: under auth.mode=disabled the AuthMiddleware is not
// registered, AppContext.Identity() is nil, and the handler emits the
// anonymous placeholder body. Under auth.mode=jwt the middleware
// requires a valid bearer — the route is NOT in auth.publicRoutes, so
// an unauthenticated call returns 401 with
// MissingAuthorizationNotification. RawSpec.Public below only affects
// the OpenAPI spec (no bearerAuth advertised on the operation); it
// does not bypass the middleware at runtime.
//
// Sits at the root (not under /users) because it describes the
// authenticated principal of any caller, not anything specific to the
// User aggregate. ShowcaseFeature mounts this alongside the other
// framework demos.
func MountWhoami(app *fiber.App, d bootstrap.Deps) {
	fwopenapi.MountRaw(d.OpenAPIRegistry, app, fiber.MethodGet, "/whoami",
		whoami,
		fwopenapi.RawSpec{
			Summary:     "Returns the authenticated identity",
			Description: "Under auth.mode=disabled the body is {\"subject\":\"anonymous\",\"authenticated\":false}. Under auth.mode=jwt the framework's AuthMiddleware populates AppContext.Identity and the body reflects the JWT subject and issuer.",
			Tags:        []string{"Auth"},
			Public:      true,
			Responses: map[int]fwopenapi.ResponseSpec{
				200: fwopenapi.ResponseOf[WhoamiResponse]("Authenticated identity or anonymous placeholder"),
			},
		})
}

// whoami reads AppContext.Identity (populated by the framework's
// AuthMiddleware) and replies with the authenticated principal or the
// anonymous placeholder.
func whoami(c fiber.Ctx) error {
	id := fwweb.AppContext(c).Identity()
	body := fiber.Map{"subject": "anonymous", "authenticated": false}
	if id != nil {
		body["subject"] = id.Subject
		body["issuer"] = id.Issuer
		body["authenticated"] = true
	}
	return fwweb.RespondWithSuccess(c, fiber.StatusOK, body)
}
