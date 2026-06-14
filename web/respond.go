package web

import (
	fwweb "github.com/ClaudioSchirmer/omnicore/web"

	"github.com/gofiber/fiber/v2"
)

// respondWithError surfaces a non-domain failure (typically an outbound call
// to an external system) with the canonical Response envelope so the
// consumer sees the same shape regardless of which handler emitted the
// failure. Description carries the operator-friendly summary; the
// underlying error (when present) is appended on the errors list so curl /
// qa scripts can see why the call failed.
//
// Used by keycloak_routes.go and showcase_routes.go — both groups talk to
// external systems and need a single envelope for 4xx / 5xx responses.
// user_routes.go does not consume this helper because the Auto Command
// Handlers + fwweb wrappers emit their own envelope through
// RespondFromResult. whoami_routes.go does not consume it because the
// endpoint never fails — it returns the anonymous placeholder when no
// Identity is present.
func respondWithError(c *fiber.Ctx, status int, description string, cause error) error {
	msg := fwweb.ErrorMessage{Message: description}
	if cause != nil {
		msg.Message = description + ": " + cause.Error()
	}
	return fwweb.Respond(c, fwweb.Response{
		Success:     false,
		Status:      status,
		Description: description,
		Errors:      []fwweb.Error{{Context: "External", Messages: []fwweb.ErrorMessage{msg}}},
	})
}
