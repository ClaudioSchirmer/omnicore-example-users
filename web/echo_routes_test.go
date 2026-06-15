package web

import (
	"bytes"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/gofiber/fiber/v3"
)

// newEchoApp builds an isolated Fiber app with only the /echo/* routes
// mounted. These tests cover the producer side of the showcase — the
// consumer side (/users/showcase/*) is integration-tested by
// qa/httpclient.sh against a running service.
func newEchoApp() *fiber.App {
	app := fiber.New()
	// d is a zero-value Deps — MountEcho only touches d.OpenAPIRegistry, which
	// is nil here, so openapi.MountRaw short-circuits to a Fiber-only register.
	MountEcho(app, bootstrap.Deps{})
	return app
}

func TestEcho_Stream_WritesRequestedByteCount(t *testing.T) {
	app := newEchoApp()
	req := httptest.NewRequest("GET", "/echo/stream/512", nil)
	resp, err := app.Test(req, fiber.TestConfig{Timeout: 0, FailOnTimeout: false})
	if err != nil {
		t.Fatalf("Test: %v", err)
	}
	if resp.StatusCode != fiber.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/octet-stream" {
		t.Errorf("Content-Type = %q, want application/octet-stream", ct)
	}
	body, _ := io.ReadAll(resp.Body)
	if len(body) != 512 {
		t.Errorf("body length = %d, want 512", len(body))
	}
}

func TestEcho_Stream_RejectsNegativeSize(t *testing.T) {
	app := newEchoApp()
	req := httptest.NewRequest("GET", "/echo/stream/-1", nil)
	resp, err := app.Test(req, fiber.TestConfig{Timeout: 0, FailOnTimeout: false})
	if err != nil {
		t.Fatalf("Test: %v", err)
	}
	if resp.StatusCode != fiber.StatusBadRequest {
		t.Fatalf("status = %d, want 400", resp.StatusCode)
	}
}

func TestEcho_Upload_EchoesByteCountAndContentType(t *testing.T) {
	app := newEchoApp()
	payload := bytes.Repeat([]byte("Z"), 128)
	req := httptest.NewRequest("POST", "/echo/upload", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "image/png")
	resp, err := app.Test(req, fiber.TestConfig{Timeout: 0, FailOnTimeout: false})
	if err != nil {
		t.Fatalf("Test: %v", err)
	}
	if resp.StatusCode != fiber.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if n, _ := body["received_bytes"].(float64); int(n) != 128 {
		t.Errorf("received_bytes = %v, want 128", body["received_bytes"])
	}
	if body["content_type"] != "image/png" {
		t.Errorf("content_type = %v, want image/png", body["content_type"])
	}
}

func TestEcho_Multipart_ParsesFieldsAndFile(t *testing.T) {
	app := newEchoApp()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	_ = mw.WriteField("category", "id-proof")
	w, _ := mw.CreateFormFile("file", "passport.pdf")
	_, _ = w.Write([]byte("PDF-BYTES"))
	_ = mw.Close()

	req := httptest.NewRequest("POST", "/echo/multipart", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	resp, err := app.Test(req, fiber.TestConfig{Timeout: 0, FailOnTimeout: false})
	if err != nil {
		t.Fatalf("Test: %v", err)
	}
	if resp.StatusCode != fiber.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	fields, _ := body["fields"].(map[string]any)
	if fields["category"] != "id-proof" {
		t.Errorf("category field = %v", fields["category"])
	}
	files, _ := body["files"].([]any)
	if len(files) != 1 {
		t.Fatalf("expected 1 file, got %d", len(files))
	}
	f, _ := files[0].(map[string]any)
	if f["filename"] != "passport.pdf" {
		t.Errorf("filename = %v", f["filename"])
	}
	if n, _ := f["size"].(float64); int(n) != len("PDF-BYTES") {
		t.Errorf("size = %v, want %d", f["size"], len("PDF-BYTES"))
	}
}

func TestEcho_SSE_StreamsThreeEvents(t *testing.T) {
	app := newEchoApp()
	req := httptest.NewRequest("GET", "/echo/sse", nil)
	resp, err := app.Test(req, fiber.TestConfig{Timeout: 0, FailOnTimeout: false})
	if err != nil {
		t.Fatalf("Test: %v", err)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Errorf("Content-Type = %q, want text/event-stream", ct)
	}
	body, _ := io.ReadAll(resp.Body)
	bs := string(body)
	if !strings.Contains(bs, "event: tick") || !strings.Contains(bs, "event: end") {
		t.Errorf("body missing expected events:\n%s", bs)
	}
	if !strings.Contains(bs, "retry: 1500") {
		t.Errorf("body missing retry hint:\n%s", bs)
	}
	if !strings.Contains(bs, "id: evt-2") {
		t.Errorf("body missing id field on second event:\n%s", bs)
	}
}

func TestEcho_Signed_CapturesHeaders(t *testing.T) {
	app := newEchoApp()
	req := httptest.NewRequest("POST", "/echo/signed", strings.NewReader("hello"))
	req.Header.Set("X-Date", "Mon, 02 Jan 2006 15:04:05 GMT")
	req.Header.Set("X-Content-SHA256", "abc123")
	req.Header.Set("X-Signature", "deadbeef")
	req.Header.Set("X-Key-Id", "demo-key-1")
	req.Header.Set("Authorization", "Bearer test-token")

	resp, err := app.Test(req, fiber.TestConfig{Timeout: 0, FailOnTimeout: false})
	if err != nil {
		t.Fatalf("Test: %v", err)
	}
	if resp.StatusCode != fiber.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	for _, k := range []string{"x_date", "x_content_sha", "x_signature", "x_key_id", "authorization"} {
		v, _ := body[k].(string)
		if v == "" {
			t.Errorf("%s missing from echo response: %#v", k, body)
		}
	}
	if body["received_body"] != "hello" {
		t.Errorf("received_body = %v", body["received_body"])
	}
}
