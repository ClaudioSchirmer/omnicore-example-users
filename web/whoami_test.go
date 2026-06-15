package web

import (
	"encoding/json"
	"io"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	"github.com/gofiber/fiber/v3"
)

// readJSON decodes the response body into a generic map for assertion.
func readJSON(t *testing.T, body io.ReadCloser) map[string]any {
	t.Helper()
	defer body.Close()
	raw, err := io.ReadAll(body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("decode body %q: %v", raw, err)
	}
	return got
}

func TestWhoami_AnonymousWhenIdentityNil(t *testing.T) {
	app := fiber.New()
	app.Use(fwweb.AppContextMiddleware())
	app.Get("/whoami", whoami)

	req := httptest.NewRequest("GET", "/whoami", nil)
	resp, err := app.Test(req, fiber.TestConfig{Timeout: 0, FailOnTimeout: false})
	if err != nil {
		t.Fatalf("app.Test: %v", err)
	}
	if resp.StatusCode != fiber.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	body := readJSON(t, resp.Body)
	data, _ := body["data"].(map[string]any)
	if data["subject"] != "anonymous" {
		t.Errorf("subject = %v, want %q", data["subject"], "anonymous")
	}
	if data["authenticated"] != false {
		t.Errorf("authenticated = %v, want false", data["authenticated"])
	}
}

func TestWhoami_ReflectsIdentityWhenPresent(t *testing.T) {
	app := fiber.New()
	app.Use(fwweb.AppContextMiddleware())
	// Simulate the auth middleware: attach an Identity to the AppContext
	// before the route runs.
	app.Use(func(c fiber.Ctx) error {
		fwweb.AppContext(c).SetIdentity(&configuration.Identity{
			Subject:   "user-42",
			Issuer:    "https://idp.test",
			ExpiresAt: time.Now().Add(1 * time.Hour),
		})
		return c.Next()
	})
	app.Get("/whoami", whoami)

	req := httptest.NewRequest("GET", "/whoami", nil)
	resp, err := app.Test(req, fiber.TestConfig{Timeout: 0, FailOnTimeout: false})
	if err != nil {
		t.Fatalf("app.Test: %v", err)
	}
	if resp.StatusCode != fiber.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	body := readJSON(t, resp.Body)
	data, _ := body["data"].(map[string]any)
	if data["subject"] != "user-42" {
		t.Errorf("subject = %v, want %q", data["subject"], "user-42")
	}
	if data["issuer"] != "https://idp.test" {
		t.Errorf("issuer = %v, want %q", data["issuer"], "https://idp.test")
	}
	if data["authenticated"] != true {
		t.Errorf("authenticated = %v, want true", data["authenticated"])
	}
}
