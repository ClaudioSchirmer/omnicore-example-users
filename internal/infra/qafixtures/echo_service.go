//go:build qa

package qafixtures

import (
	"bytes"
	"context"
	"io"
	"strings"
	"time"

	"github.com/ClaudioSchirmer/omnicore/infra/httpclient"
)

// EchoService is the consumer adapter for the in-process /echo/* routes
// that act as the upstream for the framework's streaming + signing
// showcase. The same example service exposes both ends of the demo —
// MountEcho registers the producer routes, and EchoService consumes
// them through omnicore/infra/httpclient.
//
// Two backing YAML services are declared in microservice.dev.yaml:
//
//   - `echo` — no signing block; carries the streaming endpoints
//     (download, upload-stream, multipart, sse). Signing + streaming
//     upload is rejected at call time by the framework.
//   - `echo-signed` — declares an HMAC signing block; carries the
//     non-streaming endpoint (signed). Every call against this service
//     produces timestamp + content-sha256 + signature headers.
//
// Per the framework's composition pattern, handlers depend on
// *EchoService and never import httpclient directly.
type EchoService struct {
	http *httpclient.HttpClient
}

// NewEchoService builds the adapter over the shared HttpClient registry.
// UsersFeature constructs it once at boot and injects it into the
// showcase handlers.
func NewEchoService(http *httpclient.HttpClient) *EchoService {
	return &EchoService{http: http}
}

// --- DTOs (transport-only, package-private) ------------------------------

// echoStreamRequest carries the {size} path placeholder for the download
// streaming demo.
type echoStreamRequest struct {
	Size string `http:"path,size"`
}

// echoUploadRequest pipes an arbitrary io.Reader as the request body via
// the framework's http:"body,stream" tag. The Content-Type header comes
// from the same struct so the upstream knows how to interpret the bytes.
type echoUploadRequest struct {
	Body io.Reader `http:"body,stream"`
	Mime string    `http:"header,Content-Type"`
}

// EchoUploadResponse is the upstream's reply to an upload: byte count
// and the Content-Type it observed. Exported so the consumer side can
// surface it as the showcase response payload.
type EchoUploadResponse struct {
	ReceivedBytes int    `json:"received_bytes"`
	ContentType   string `json:"content_type"`
}

// echoMultipartRequest carries an httpclient.Multipart value tagged as
// http:"body,multipart". The framework writes the multipart body through
// an io.Pipe so file contents stream rather than buffer.
type echoMultipartRequest struct {
	Body httpclient.Multipart `http:"body,multipart"`
}

// EchoMultipartFile is the per-file projection echoed by the upstream.
type EchoMultipartFile struct {
	Name     string `json:"name"`
	Filename string `json:"filename"`
	MimeType string `json:"mime"`
	Size     int    `json:"size"`
}

// EchoMultipartResponse mirrors the upstream's structure: text fields
// and file summaries.
type EchoMultipartResponse struct {
	Fields map[string]string   `json:"fields"`
	Files  []EchoMultipartFile `json:"files"`
}

// echoSignedRequest sends a JSON body to the signed endpoint; the
// framework hashes the body to populate X-Content-SHA256 and signs the
// canonical string.
type echoSignedRequest struct {
	Body any `http:"body,json"`
}

// EchoSignedResponse captures the signing headers the upstream
// observed. The consumer can assert end-to-end signing by checking that
// every header is non-empty.
type EchoSignedResponse struct {
	ObservedAt    string `json:"observed_at"`
	ReceivedBytes int    `json:"received_bytes"`
	ReceivedBody  string `json:"received_body"`
	XDate         string `json:"x_date"`
	XContentSHA   string `json:"x_content_sha"`
	XSignature    string `json:"x_signature"`
	XKeyID        string `json:"x_key_id"`
	Authorization string `json:"authorization"`
}

// --- Business methods ----------------------------------------------------

// DownloadStream fetches `size` bytes from the /echo/stream/:size
// endpoint as a StreamResponse, copies the body into a buffer, and
// returns the byte count plus a hash-style fingerprint of the first
// bytes. Exercises the download streaming surface.
func (s *EchoService) DownloadStream(ctx context.Context, size string) (int64, string, error) {
	resp, err := httpclient.Call[echoStreamRequest, httpclient.StreamResponse](
		ctx, s.http,
		"echo", "download",
		echoStreamRequest{Size: size},
	)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	var buf bytes.Buffer
	n, err := io.Copy(&buf, resp.Body)
	if err != nil {
		return 0, "", err
	}
	// Sample the first 16 bytes of the body so the QA suite can verify
	// the stream piped through unchanged without echoing potentially
	// large payloads back to the caller.
	sample := buf.Bytes()
	if len(sample) > 16 {
		sample = sample[:16]
	}
	return n, string(sample), nil
}

// UploadStream pipes an io.Reader as the request body to /echo/upload
// via the http:"body,stream" tag. Returns the upstream's observed byte
// count and Content-Type. Exercises the upload streaming surface.
func (s *EchoService) UploadStream(ctx context.Context, body io.Reader, contentType string) (EchoUploadResponse, error) {
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	return httpclient.Call[echoUploadRequest, EchoUploadResponse](
		ctx, s.http,
		"echo", "uploadStream",
		echoUploadRequest{Body: body, Mime: contentType},
	)
}

// UploadMultipart synthesizes a multipart body from the supplied parts
// and POSTs it to /echo/multipart via the http:"body,multipart" tag.
func (s *EchoService) UploadMultipart(ctx context.Context, fields []httpclient.MultipartField, files []httpclient.MultipartFile) (EchoMultipartResponse, error) {
	return httpclient.Call[echoMultipartRequest, EchoMultipartResponse](
		ctx, s.http,
		"echo", "multipart",
		echoMultipartRequest{Body: httpclient.Multipart{Fields: fields, Files: files}},
	)
}

// SubscribeEvents opens an SSE stream to /echo/sse, drains every event
// the framework's EventSource parser dispatches, and returns them as a
// slice. Bounded by ctx and the upstream's natural EOF — the demo
// upstream sends 3 events and closes.
func (s *EchoService) SubscribeEvents(ctx context.Context) ([]EchoEvent, error) {
	resp, err := httpclient.Call[struct{}, httpclient.SSEResponse](
		ctx, s.http,
		"echo", "sse",
		struct{}{},
	)
	if err != nil {
		return nil, err
	}
	defer resp.Close()
	events := []EchoEvent{}
	timeout := time.After(3 * time.Second)
	for {
		select {
		case ev, ok := <-resp.Events:
			if !ok {
				return events, nil
			}
			events = append(events, EchoEvent{
				ID:      ev.ID,
				Event:   ev.Event,
				Data:    string(ev.Data),
				RetryMS: int64(ev.Retry / time.Millisecond),
			})
		case <-timeout:
			return events, nil
		case <-ctx.Done():
			return events, ctx.Err()
		}
	}
}

// EchoEvent is the consumer-friendly projection of one SSE event.
type EchoEvent struct {
	ID      string `json:"id,omitempty"`
	Event   string `json:"event"`
	Data    string `json:"data"`
	RetryMS int64  `json:"retry_ms,omitempty"`
}

// SignedRoundTrip POSTs a JSON body to /echo/signed via the `echo-signed`
// service. The framework injects X-Date + X-Content-SHA256 + X-Signature
// (and X-Key-Id when the YAML declared keyId) before dialing; the
// upstream echoes them back so the consumer proves HMAC signing
// executed.
func (s *EchoService) SignedRoundTrip(ctx context.Context, payload any) (EchoSignedResponse, error) {
	return httpclient.Call[echoSignedRequest, EchoSignedResponse](
		ctx, s.http,
		"echo-signed", "signed",
		echoSignedRequest{Body: payload},
	)
}

// WithConfigOverride exercises CallConfig per-call overrides. The YAML
// endpoint `echo.uploadStream` is declared as POST /echo/upload with no
// streaming flags on the response side; the showcase here re-specifies
// the path via CallConfig and substitutes a json-tagged request DTO so
// the framework's binding sends a JSON body instead of piping a stream.
// Proves that CallConfig.Method, CallConfig.Path and CallConfig.RequestCodec
// are accepted at call time without touching the YAML or breaking the
// dispatch. Returns the upstream's observed byte count.
func (s *EchoService) WithConfigOverride(ctx context.Context, body string) (EchoUploadResponse, error) {
	type req struct {
		Body any `http:"body,json"`
	}
	return httpclient.Call[req, EchoUploadResponse](
		ctx, s.http,
		"echo", "uploadStream",
		req{Body: map[string]string{"payload": body}},
		httpclient.WithConfig(httpclient.CallConfig{
			Method: "POST",
			Path:   "/echo/upload",
		}),
	)
}

// InlineBearerRoundTrip exercises CallConfig.InlineAuth.Bearer. The
// upstream (/echo/signed) does not validate the bearer; the demo
// proves the framework attached Authorization: Bearer <token> by
// reading the header back from the upstream's reply. The endpoint used
// is the signed one because its handler returns the Authorization
// header it observed.
func (s *EchoService) InlineBearerRoundTrip(ctx context.Context, token, payload string) (EchoSignedResponse, error) {
	if strings.TrimSpace(token) == "" {
		token = "demo-bearer-token"
	}
	return httpclient.Call[echoSignedRequest, EchoSignedResponse](
		ctx, s.http,
		"echo-signed", "signed",
		echoSignedRequest{Body: payload},
		httpclient.WithConfig(httpclient.CallConfig{
			InlineAuth: &httpclient.InlineAuth{Bearer: token},
		}),
	)
}
