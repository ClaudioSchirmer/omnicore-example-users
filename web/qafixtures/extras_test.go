//go:build qa

package qafixtures

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	"github.com/gofiber/fiber/v3"
)

// freshApp returns a Fiber app pre-wired with the framework's AppContext
// middleware so handlers calling fwweb.AppContext(c) see a valid context.
func freshApp() *fiber.App {
	app := fiber.New()
	app.Use(fwweb.AppContextMiddleware())
	return app
}

// --- respond.go -----------------------------------------------------------

func TestRespondWithError_PopulatesEnvelope(t *testing.T) {
	app := freshApp()
	app.Get("/x", func(c fiber.Ctx) error {
		return respondWithError(c, fiber.StatusBadGateway, "upstream down", errors.New("dial timeout"))
	})
	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/x", nil))
	if err != nil {
		t.Fatalf("Test: %v", err)
	}
	if resp.StatusCode != fiber.StatusBadGateway {
		t.Errorf("status = %d, want 502", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	var got fwweb.Response
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("unmarshal: %v body=%s", err, body)
	}
	if got.Success {
		t.Error("envelope should be Success=false")
	}
	if len(got.Errors) != 1 || got.Errors[0].Context != "External" {
		t.Errorf("Errors = %+v", got.Errors)
	}
	if !strings.Contains(got.Errors[0].Messages[0].Message, "dial timeout") {
		t.Errorf("message should embed the cause, got %q", got.Errors[0].Messages[0].Message)
	}
}

func TestRespondWithError_NilCauseOmitsDetail(t *testing.T) {
	app := freshApp()
	app.Get("/x", func(c fiber.Ctx) error {
		return respondWithError(c, fiber.StatusServiceUnavailable, "down", nil)
	})
	resp, _ := app.Test(httptest.NewRequest(fiber.MethodGet, "/x", nil))
	body, _ := io.ReadAll(resp.Body)
	var got fwweb.Response
	_ = json.Unmarshal(body, &got)
	if msg := got.Errors[0].Messages[0].Message; msg != "down" {
		t.Errorf("nil cause Message = %q, want bare description", msg)
	}
}

// --- whoami_routes.go -----------------------------------------------------

func TestWhoami_AnonymousResponseWhenNoIdentity(t *testing.T) {
	app := freshApp()
	MountWhoami(app, bootstrap.Deps{})

	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/whoami", nil))
	if err != nil {
		t.Fatalf("Test: %v", err)
	}
	if resp.StatusCode != fiber.StatusOK {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), `"subject":"anonymous"`) {
		t.Errorf("body should carry anonymous placeholder, got %s", body)
	}
	if !strings.Contains(string(body), `"authenticated":false`) {
		t.Errorf("authenticated flag should be false, got %s", body)
	}
}

func TestWhoami_PopulatesFromIdentity(t *testing.T) {
	app := freshApp()
	// Inject an Identity via a middleware that runs AFTER AppContextMiddleware.
	app.Use(func(c fiber.Ctx) error {
		fwweb.AppContext(c).SetIdentity(&configuration.Identity{
			Subject: "alice-uuid",
			Issuer:  "https://idp.example",
		})
		return c.Next()
	})
	MountWhoami(app, bootstrap.Deps{})

	resp, _ := app.Test(httptest.NewRequest(fiber.MethodGet, "/whoami", nil))
	body, _ := io.ReadAll(resp.Body)
	s := string(body)
	if !strings.Contains(s, `"subject":"alice-uuid"`) {
		t.Errorf("subject missing in body: %s", s)
	}
	if !strings.Contains(s, `"issuer":"https://idp.example"`) {
		t.Errorf("issuer missing in body: %s", s)
	}
	if !strings.Contains(s, `"authenticated":true`) {
		t.Errorf("authenticated should be true, body=%s", s)
	}
}

// --- echo_routes.go -------------------------------------------------------

func TestEchoStream_WritesNBytes(t *testing.T) {
	app := freshApp()
	MountEcho(app, bootstrap.Deps{})

	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/echo/stream/64", nil))
	if err != nil {
		t.Fatalf("Test: %v", err)
	}
	if resp.StatusCode != fiber.StatusOK {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if len(body) != 64 {
		t.Errorf("body len = %d, want 64 (Content-Length stripped by app.Test stream mode)", len(body))
	}
}

func TestEchoStream_InvalidSize(t *testing.T) {
	app := freshApp()
	MountEcho(app, bootstrap.Deps{})
	for _, path := range []string{"/echo/stream/abc", "/echo/stream/-1"} {
		resp, _ := app.Test(httptest.NewRequest(fiber.MethodGet, path, nil))
		if resp.StatusCode != fiber.StatusBadRequest {
			t.Errorf("%s status = %d, want 400", path, resp.StatusCode)
		}
	}
}

func TestEchoStream_OverCapRejected(t *testing.T) {
	app := freshApp()
	MountEcho(app, bootstrap.Deps{})
	resp, _ := app.Test(httptest.NewRequest(fiber.MethodGet, "/echo/stream/20971520", nil)) // 20 MiB > 16 MiB cap
	if resp.StatusCode != fiber.StatusBadRequest {
		t.Errorf("over-cap status = %d, want 400", resp.StatusCode)
	}
}

func TestEchoUpload_ReceivesByteCount(t *testing.T) {
	app := freshApp()
	MountEcho(app, bootstrap.Deps{})

	req := httptest.NewRequest(fiber.MethodPost, "/echo/upload", strings.NewReader("hello"))
	req.Header.Set("Content-Type", "text/plain")
	resp, _ := app.Test(req)
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), `"received_bytes":5`) {
		t.Errorf("upload body should carry received_bytes=5, got %s", body)
	}
	if !strings.Contains(string(body), `"content_type":"text/plain"`) {
		t.Errorf("upload body should echo content_type, got %s", body)
	}
}

func TestEchoMultipart_RejectsNonMultipart(t *testing.T) {
	app := freshApp()
	MountEcho(app, bootstrap.Deps{})
	req := httptest.NewRequest(fiber.MethodPost, "/echo/multipart", strings.NewReader("x"))
	req.Header.Set("Content-Type", "application/json")
	resp, _ := app.Test(req)
	if resp.StatusCode != fiber.StatusBadRequest {
		t.Errorf("status = %d, want 400 on non-multipart", resp.StatusCode)
	}
}

func TestEchoMultipart_ParsesFieldsAndFiles(t *testing.T) {
	app := freshApp()
	MountEcho(app, bootstrap.Deps{})

	body, contentType := buildMultipart(t,
		map[string]string{"category": "doc"},
		map[string]string{"file": "PDF-DATA"},
	)
	req := httptest.NewRequest(fiber.MethodPost, "/echo/multipart", strings.NewReader(body))
	req.Header.Set("Content-Type", contentType)
	resp, err := app.Test(req)
	if err != nil {
		t.Fatalf("Test: %v", err)
	}
	if resp.StatusCode != fiber.StatusOK {
		raw, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, body = %s", resp.StatusCode, raw)
	}
	raw, _ := io.ReadAll(resp.Body)
	var got struct {
		Fields map[string]string `json:"fields"`
		Files  []struct {
			Filename string `json:"filename"`
			Size     int    `json:"size"`
		} `json:"files"`
	}
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("unmarshal: %v\nbody=%s", err, raw)
	}
	if got.Fields["category"] != "doc" {
		t.Errorf("fields = %+v", got.Fields)
	}
	if len(got.Files) != 1 || got.Files[0].Size != len("PDF-DATA") {
		t.Errorf("files = %+v", got.Files)
	}
}

func TestEchoSSE_StreamsContentType(t *testing.T) {
	app := freshApp()
	MountEcho(app, bootstrap.Deps{})

	resp, err := app.Test(httptest.NewRequest(fiber.MethodGet, "/echo/sse", nil))
	if err != nil {
		t.Fatalf("Test: %v", err)
	}
	if resp.StatusCode != fiber.StatusOK {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}
	if !strings.Contains(resp.Header.Get("Content-Type"), "text/event-stream") {
		t.Errorf("Content-Type = %q", resp.Header.Get("Content-Type"))
	}
	body, _ := io.ReadAll(resp.Body)
	s := string(body)
	for _, want := range []string{"event: tick", "data: 1", "id: evt-2", "event: end", "retry: 1500"} {
		if !strings.Contains(s, want) {
			t.Errorf("SSE body missing %q\nfull: %s", want, s)
		}
	}
}

func TestEchoSigned_EchoesSigningHeaders(t *testing.T) {
	app := freshApp()
	MountEcho(app, bootstrap.Deps{})

	req := httptest.NewRequest(fiber.MethodPost, "/echo/signed", strings.NewReader(`{"x":1}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Date", "2026-06-11T10:00:00Z")
	req.Header.Set("X-Content-SHA256", "abc")
	req.Header.Set("X-Signature", "sig")
	req.Header.Set("X-Key-Id", "kid")
	req.Header.Set("Authorization", "Bearer t")
	resp, _ := app.Test(req)
	body, _ := io.ReadAll(resp.Body)
	for _, want := range []string{
		`"x_date":"2026-06-11T10:00:00Z"`,
		`"x_content_sha":"abc"`,
		`"x_signature":"sig"`,
		`"x_key_id":"kid"`,
		`"authorization":"Bearer t"`,
		`"received_body":"{\"x\":1}"`,
	} {
		if !strings.Contains(string(body), want) {
			t.Errorf("signed echo missing %q\nfull: %s", want, body)
		}
	}
}

// --- helpers --------------------------------------------------------------

func buildMultipart(t *testing.T, fields, files map[string]string) (body string, contentType string) {
	t.Helper()
	const boundary = "----test-bnd"
	var b strings.Builder
	for k, v := range fields {
		b.WriteString("--")
		b.WriteString(boundary)
		b.WriteString("\r\nContent-Disposition: form-data; name=")
		b.WriteString(`"` + k + `"`)
		b.WriteString("\r\n\r\n")
		b.WriteString(v)
		b.WriteString("\r\n")
	}
	for name, data := range files {
		b.WriteString("--")
		b.WriteString(boundary)
		b.WriteString("\r\nContent-Disposition: form-data; name=")
		b.WriteString(`"` + name + `"; filename="x.bin"`)
		b.WriteString("\r\nContent-Type: application/octet-stream\r\n\r\n")
		b.WriteString(data)
		b.WriteString("\r\n")
	}
	b.WriteString("--")
	b.WriteString(boundary)
	b.WriteString("--\r\n")
	return b.String(), `multipart/form-data; boundary=` + boundary
}

// stub for unused imports so coverage build is clean
var _ = http.StatusOK
