package requests

import (
	"net/http/httptest"
	"testing"

	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	"github.com/gofiber/fiber/v3"
)

// TestUserCustomKeyRequest_BindPath_PopulatesDocument asserts the
// `path:"document"` tag is wired so fwweb.BindPath copies the :document URL
// segment into req.Document. This is the only behavior the shared DTO
// carries — the Command assembly happens inline on each route, so there
// is no ToCommand method to exercise here.
func TestUserCustomKeyRequest_BindPath_PopulatesDocument(t *testing.T) {
	app := fiber.New()

	var bound UserCustomKeyRequest
	var ok bool
	var badField string

	app.Patch("/showcase/users-custom/:document/archive", func(c fiber.Ctx) error {
		var req UserCustomKeyRequest
		badField, ok = fwweb.BindPath(c, &req)
		bound = req
		return c.SendStatus(fiber.StatusOK)
	})

	resp, err := app.Test(httptest.NewRequest("PATCH", "/showcase/users-custom/10000000001/archive", nil), fiber.TestConfig{Timeout: 0, FailOnTimeout: false})
	if err != nil {
		t.Fatalf("app.Test: %v", err)
	}
	if resp.StatusCode != fiber.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if !ok {
		t.Fatalf("BindPath returned ok=false, badField=%q", badField)
	}
	if bound.Document != "10000000001" {
		t.Errorf("bound.Document = %q, want %q", bound.Document, "10000000001")
	}
}
