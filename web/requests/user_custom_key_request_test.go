package requests

import (
	"net/http/httptest"
	"testing"

	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	"github.com/gofiber/fiber/v2"
)

// TestUserCustomKeyRequest_BindPath_PopulatesEmail asserts the
// `path:"email"` tag is wired so fwweb.BindPath copies the :email URL
// segment into req.Email. This is the only behavior the shared DTO
// carries — the Command assembly happens inline on each route, so there
// is no ToCommand method to exercise here.
func TestUserCustomKeyRequest_BindPath_PopulatesEmail(t *testing.T) {
	app := fiber.New()

	var bound UserCustomKeyRequest
	var ok bool
	var badField string

	app.Patch("/showcase/users-custom/:email/archive", func(c *fiber.Ctx) error {
		var req UserCustomKeyRequest
		badField, ok = fwweb.BindPath(c, &req)
		bound = req
		return c.SendStatus(fiber.StatusOK)
	})

	resp, err := app.Test(httptest.NewRequest("PATCH", "/showcase/users-custom/jane@example.com/archive", nil), -1)
	if err != nil {
		t.Fatalf("app.Test: %v", err)
	}
	if resp.StatusCode != fiber.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if !ok {
		t.Fatalf("BindPath returned ok=false, badField=%q", badField)
	}
	if bound.Email != "jane@example.com" {
		t.Errorf("bound.Email = %q, want %q", bound.Email, "jane@example.com")
	}
}
