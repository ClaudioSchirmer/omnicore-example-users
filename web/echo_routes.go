package web

import (
	"bytes"
	"io"
	"mime"
	"mime/multipart"
	"strconv"
	"time"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"

	"github.com/gofiber/fiber/v2"
)

// MountEcho registers the /echo/* routes that act as the upstream for the
// /users/showcase/* demos. They live in the same service so the showcase
// is self-contained — the example's httpClient block points the `echo`
// and `echo-signed` services at this very process's HTTP address. The
// pattern is a one-binary demo of every outbound feature without a new
// docker-compose container.
//
// These routes carry no auth, no business logic, no persistence. They
// echo bytes / parse multipart / stream SSE events / capture signing
// headers and reply with what they saw. The QA suite's httpclient.sh
// asserts against the showcase routes (the consumer side); these are the
// producer side.
func MountEcho(app *fiber.App, d bootstrap.Deps) {
	echo := app.Group("/echo")

	// Echo routes are the upstream of /showcase/httpclient/* — they
	// exist solely so the framework demos have an in-process producer
	// to call. Hidden: true keeps them out of the rendered spec while
	// still registering on Fiber (the showcase routes need them
	// reachable at runtime). Public: true is paired with Hidden so a
	// future operator wanting to surface them via a custom RawSpec
	// override does not regress into "marked auth-required". Auth is
	// disabled across these routes regardless via the publicRoutes
	// list when the service runs under auth.mode=jwt.
	hidden := fwopenapi.RawSpec{Hidden: true, Public: true}

	fwopenapi.MountRaw(d.OpenAPIRegistry, echo, fiber.MethodGet, "/stream/:size", echoStream, hidden)
	fwopenapi.MountRaw(d.OpenAPIRegistry, echo, fiber.MethodPost, "/upload", echoUpload, hidden)
	fwopenapi.MountRaw(d.OpenAPIRegistry, echo, fiber.MethodPost, "/multipart", echoMultipart, hidden)
	fwopenapi.MountRaw(d.OpenAPIRegistry, echo, fiber.MethodGet, "/sse", echoSSE, hidden)
	fwopenapi.MountRaw(d.OpenAPIRegistry, echo, fiber.MethodPost, "/signed", echoSigned, hidden)
}

// echoStream writes :size bytes of "X" with Content-Type
// application/octet-stream so the consumer can copy the body via the
// httpclient StreamResponse path. Cap at 16 MiB so a typo doesn't spawn
// an unbounded transfer.
func echoStream(c *fiber.Ctx) error {
	size, err := strconv.Atoi(c.Params("size"))
	if err != nil || size < 0 {
		return fiber.NewError(fiber.StatusBadRequest, "size must be a non-negative integer")
	}
	if size > 16*1024*1024 {
		return fiber.NewError(fiber.StatusBadRequest, "size capped at 16 MiB for the demo")
	}
	c.Set(fiber.HeaderContentType, "application/octet-stream")
	c.Set(fiber.HeaderContentLength, strconv.Itoa(size))
	return c.SendStream(bytes.NewReader(bytes.Repeat([]byte("X"), size)))
}

// echoUpload reads the request body verbatim and replies with the byte
// count and the Content-Type it saw. Useful for proving the streaming
// upload tag (http:"body,stream") piped the bytes intact.
func echoUpload(c *fiber.Ctx) error {
	body := c.Body()
	return c.JSON(fiber.Map{
		"received_bytes": len(body),
		"content_type":   string(c.Request().Header.ContentType()),
	})
}

// echoMultipart parses multipart/form-data, surfaces the fields and a
// summary of each file (name, filename, mime, size). The consumer side
// asserts the structure matches what the framework's binding layer
// produced via the io.Pipe multipart writer.
func echoMultipart(c *fiber.Ctx) error {
	mediatype, params, err := mime.ParseMediaType(string(c.Request().Header.ContentType()))
	if err != nil || mediatype != "multipart/form-data" {
		return fiber.NewError(fiber.StatusBadRequest, "expected multipart/form-data")
	}
	mr := multipart.NewReader(bytes.NewReader(c.Body()), params["boundary"])
	fields := map[string]string{}
	files := []fiber.Map{}
	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fiber.NewError(fiber.StatusBadRequest, "multipart parse error: "+err.Error())
		}
		data, _ := io.ReadAll(part)
		if part.FileName() != "" {
			files = append(files, fiber.Map{
				"name":     part.FormName(),
				"filename": part.FileName(),
				"mime":     part.Header.Get("Content-Type"),
				"size":     len(data),
			})
		} else {
			fields[part.FormName()] = string(data)
		}
	}
	return c.JSON(fiber.Map{"fields": fields, "files": files})
}

// echoSSE streams 3 hardcoded events plus a final blank line so the
// EventSource parser dispatches the last event before EOF. Includes an
// id: field on the second event and a retry: hint on the third so the
// consumer can assert the parser surfaces them on SSEvent.
func echoSSE(c *fiber.Ctx) error {
	c.Set(fiber.HeaderContentType, "text/event-stream")
	c.Set("Cache-Control", "no-cache")
	body := "event: tick\ndata: 1\n\n" +
		"event: tick\nid: evt-2\ndata: 2\n\n" +
		"event: end\ndata: stop\nretry: 1500\n\n"
	return c.SendString(body)
}

// echoSigned captures the signing-related headers the framework injected
// and replies with them so the consumer can prove that signing ran end
// to end. Body bytes are echoed too so the consumer can verify content
// integrity against the X-Content-SHA256 hash without re-hashing.
func echoSigned(c *fiber.Ctx) error {
	body := c.Body()
	return c.JSON(fiber.Map{
		"observed_at":     time.Now().UTC().Format(time.RFC3339),
		"received_bytes":  len(body),
		"received_body":   string(body),
		"x_date":          string(c.Request().Header.Peek("X-Date")),
		"x_content_sha":   string(c.Request().Header.Peek("X-Content-SHA256")),
		"x_signature":     string(c.Request().Header.Peek("X-Signature")),
		"x_key_id":        string(c.Request().Header.Peek("X-Key-Id")),
		"authorization":   string(c.Request().Header.Peek("Authorization")),
	})
}

