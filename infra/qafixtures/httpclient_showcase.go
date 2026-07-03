//go:build qa

package qafixtures

import (
	"context"
	"encoding/xml"

	"github.com/ClaudioSchirmer/omnicore/infra/httpclient"
)

// QaHttpShowcase is the QA-only outbound adapter that exercises the outbound
// httpclient middleware the canonical EchoService (infra/external) does not
// cover: retry backoff, circuit breaker, idempotency-key injection, the XML
// request codec, a static auth provider, and per-call WithExtraHeader.
//
// It calls the in-process /qa/echo/* upstream (registered by
// web/qafixtures.MountQaEcho) through two YAML-declared services:
//
//   - `qa-echo`      — flaky (retry), always500 (breaker), idempotency, xml.
//   - `qa-echo-auth` — headers, behind a static auth provider.
//
// Per the framework's composition pattern, handlers depend on *QaHttpShowcase
// and never import httpclient directly. Present only in the `qa` build.
type QaHttpShowcase struct {
	http *httpclient.HttpClient
}

// NewQaHttpShowcase builds the adapter over the shared HttpClient registry.
// GadgetFeature constructs it once at boot and injects it into the showcase
// routes.
func NewQaHttpShowcase(http *httpclient.HttpClient) *QaHttpShowcase {
	return &QaHttpShowcase{http: http}
}

// --- DTOs (transport-only, package-private) ------------------------------

// flakyRequest carries the ?key= and ?failFor= query parameters that drive
// the stateful upstream. The framework binds them onto the query string via
// the http:"query,..." tags.
type flakyRequest struct {
	Key     string `http:"query,key"`
	FailFor int    `http:"query,failFor"`
}

// FlakyResponse is the upstream's success reply once the retrying Call has
// climbed past the failFor threshold.
type FlakyResponse struct {
	Attempts int  `json:"attempts"`
	OK       bool `json:"ok"`
}

// idempotencyRequest sends a small JSON body so the POST has content; the
// framework injects the X-Idempotency-Key header (source: ctx) which the
// upstream echoes back.
type idempotencyRequest struct {
	Body any `http:"body,json"`
}

// IdempotencyResponse carries the idempotency key the upstream observed.
type IdempotencyResponse struct {
	IdempotencyKey string `json:"idempotencyKey"`
}

// gadgetXML is the xml-serializable request body for the XML codec demo. The
// framework marshals it to <gadget><code>..</code></gadget> because the
// endpoint declares requestCodec: xml and the field is tagged http:"body,xml".
type gadgetXML struct {
	XMLName xml.Name `xml:"gadget"`
	Code    string   `xml:"code"`
}

// xmlRequest wraps the xml body with the http:"body,xml" tag.
type xmlRequest struct {
	Body gadgetXML `http:"body,xml"`
}

// XMLResponse carries the code the upstream parsed out of the XML body.
type XMLResponse struct {
	Code string `json:"code"`
}

// HeadersResponse mirrors the selected request headers the upstream echoed:
// the static auth provider's Authorization, the YAML static X-Api-Key, and
// the per-call WithExtraHeader X-Extra.
type HeadersResponse struct {
	Authorization string `json:"authorization"`
	XApiKey       string `json:"xApiKey"`
	XExtra        string `json:"xExtra"`
}

// --- Business methods ----------------------------------------------------

// Flaky calls the `qa-echo`/`flaky` endpoint, which fails with 503 for the
// first failFor hits of a given key and then succeeds. With the endpoint's
// retry block (retryOn 503, maxAttempts 3) the framework replays the same GET
// — same key → the upstream counter climbs → the Call recovers on attempt
// failFor+1. Returns the upstream's observed attempt count.
func (s *QaHttpShowcase) Flaky(ctx context.Context, key string, failFor int) (int, error) {
	resp, err := httpclient.Call[flakyRequest, FlakyResponse](
		ctx, s.http,
		"qa-echo", "flaky",
		flakyRequest{Key: key, FailFor: failFor},
	)
	if err != nil {
		return 0, err
	}
	return resp.Attempts, nil
}

// TripBreaker calls the `qa-echo`/`always500` endpoint, which always returns
// 503. Every call records a breaker failure; after the defaults-level
// failureThreshold consecutive failures the per-(service,endpoint) breaker
// opens and subsequent calls fail fast with httpclient.ErrCircuitOpen without
// dialing. Returns the call error so the showcase can loop and detect the
// open-circuit sentinel.
func (s *QaHttpShowcase) TripBreaker(ctx context.Context) error {
	_, err := httpclient.Call[struct{}, struct{}](
		ctx, s.http,
		"qa-echo", "always500",
		struct{}{},
	)
	return err
}

// Idempotency POSTs to the `qa-echo`/`idempotency` endpoint, which declares
// idempotency: { header: X-Idempotency-Key, source: ctx }. The framework
// generates a UUIDv7 and attaches it; the upstream echoes it back. A non-empty
// return value proves the client injected the key.
func (s *QaHttpShowcase) Idempotency(ctx context.Context) (string, error) {
	resp, err := httpclient.Call[idempotencyRequest, IdempotencyResponse](
		ctx, s.http,
		"qa-echo", "idempotency",
		idempotencyRequest{Body: map[string]string{"probe": "idempotency"}},
	)
	if err != nil {
		return "", err
	}
	return resp.IdempotencyKey, nil
}

// SendXML POSTs an XML body to the `qa-echo`/`xml` endpoint via the
// http:"body,xml" tag + requestCodec: xml. The upstream parses the XML and
// returns the code as JSON, proving the client serialized XML on the wire.
func (s *QaHttpShowcase) SendXML(ctx context.Context, code string) (string, error) {
	resp, err := httpclient.Call[xmlRequest, XMLResponse](
		ctx, s.http,
		"qa-echo", "xml",
		xmlRequest{Body: gadgetXML{Code: code}},
	)
	if err != nil {
		return "", err
	}
	return resp.Code, nil
}

// Headers GETs the `qa-echo-auth`/`headers` endpoint. That service is bound to
// a static auth provider (bearer-static → Authorization) and declares a static
// X-Api-Key header; the call adds a runtime X-Extra via WithExtraHeader. The
// upstream echoes all three back, proving the auth provider + the per-call
// header injection both landed on the request.
func (s *QaHttpShowcase) Headers(ctx context.Context, extra string) (HeadersResponse, error) {
	return httpclient.Call[struct{}, HeadersResponse](
		ctx, s.http,
		"qa-echo-auth", "headers",
		struct{}{},
		httpclient.WithExtraHeader("X-Extra", extra),
	)
}
