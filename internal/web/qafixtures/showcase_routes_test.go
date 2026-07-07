//go:build integration && qa

package qafixtures

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/httpclient"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	"github.com/gofiber/fiber/v3"

	infraqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/infra/qafixtures"
)

// fakeUpstream wires a single httptest.Server that routes by exact path.
type fakeUpstream struct {
	t      *testing.T
	server *httptest.Server
	mu     *http.ServeMux
}

func newFakeUpstream(t *testing.T) *fakeUpstream {
	t.Helper()
	mu := http.NewServeMux()
	srv := httptest.NewServer(mu)
	t.Cleanup(srv.Close)
	return &fakeUpstream{t: t, server: srv, mu: mu}
}

func (f *fakeUpstream) handle(path string, h http.HandlerFunc) {
	f.mu.HandleFunc(path, h)
}

// buildHTTPClient is the smallest httpclient.Config that drives the
// keycloak-public + keycloak-admin + keycloak-tenant + echo + echo-signed
// services against the fake upstream. Each test uses the subset it needs;
// declaring the full set keeps the helper compact.
func buildHTTPClient(t *testing.T, baseURL string) *httpclient.HttpClient {
	t.Helper()
	hc, err := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"keycloak-public": {
				BaseURL: baseURL,
				Endpoints: map[string]httpclient.EndpointConfig{
					"getRealmInfo": {Method: "GET", Path: "/.well-known"},
				},
			},
			"keycloak-admin": {
				BaseURL: baseURL,
				Auth:    &httpclient.ServiceAuthConfig{Provider: "kc-admin"},
				Endpoints: map[string]httpclient.EndpointConfig{
					"getUser": {Method: "GET", Path: "/admin/users/{id}", AcceptableStatus: []int{404}},
				},
			},
			"keycloak-tenant": {
				BaseURL: baseURL,
				Auth:    &httpclient.ServiceAuthConfig{Provider: "kc-tenant"},
				Endpoints: map[string]httpclient.EndpointConfig{
					"whoami": {Method: "GET", Path: "/userinfo"},
				},
			},
			"echo": {
				BaseURL: baseURL,
				Endpoints: map[string]httpclient.EndpointConfig{
					"download":     {Method: "GET", Path: "/echo/stream/{size}", ResponseStream: true},
					"uploadStream": {Method: "POST", Path: "/echo/upload"},
					"multipart":    {Method: "POST", Path: "/echo/multipart"},
					"sse":          {Method: "GET", Path: "/echo/sse", ResponseSSE: true},
				},
			},
			"echo-signed": {
				BaseURL: baseURL,
				Signing: &httpclient.SigningConfig{
					Type: "hmac-sha256", Secret: "shh",
					SignedHeaders: []string{"host"}, TimestampHeader: "X-Date",
					ContentSHA256Header: "X-Content-SHA256", SignatureHeader: "X-Signature",
				},
				Endpoints: map[string]httpclient.EndpointConfig{
					"signed": {Method: "POST", Path: "/echo/signed"},
				},
			},
		},
		AuthProviders: map[string]httpclient.AuthProviderConfig{
			"kc-admin": {
				Type: "oauth2-client-credentials", TokenEndpoint: baseURL + "/token",
				ClientID: "c", ClientSecret: "s",
				TokenCache: &httpclient.TokenCacheConfig{Source: "response-field", JSONPath: "$.expires_in", Unit: "seconds",
					Skew: httpclient.Duration(30 * time.Second)},
			},
			"kc-tenant": {
				Type: "credentials-exchange", TokenEndpoint: baseURL + "/token",
				RequestCodec: "form-urlencoded",
				RequestFieldsFromCtx: map[string]string{
					"username": "tenant.username", "password": "tenant.password",
				},
				ResponseTokenPath: "$.access_token",
				TokenCache: &httpclient.TokenCacheConfig{Source: "response-field", JSONPath: "$.expires_in", Unit: "seconds",
					Skew: httpclient.Duration(30 * time.Second)},
			},
		},
	})
	if err != nil {
		t.Fatalf("httpclient.New: %v", err)
	}
	return hc
}

// freshAppWithContext returns a Fiber app wired with AppContextMiddleware.
func freshAppWithCtx() *fiber.App {
	app := fiber.New()
	app.Use(fwweb.AppContextMiddleware())
	return app
}

// --- keycloakRealm handler -----------------------------------------------

func TestKeycloakRealmRoute(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/.well-known", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issuer": "http://" + r.Host,
		})
	})
	hc := buildHTTPClient(t, up.server.URL)
	kc := infraqa.NewKeycloakService(hc)

	app := freshAppWithCtx()
	app.Get("/r", keycloakRealm(kc))

	resp, _ := app.Test(httptest.NewRequest(fiber.MethodGet, "/r", nil))
	if resp.StatusCode != fiber.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), `"success":true`) {
		t.Errorf("envelope should be success=true, got %s", body)
	}
}

func TestKeycloakRealmRoute_UpstreamErrorReturnsBadGateway(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/.well-known", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "down", http.StatusInternalServerError)
	})
	hc := buildHTTPClient(t, up.server.URL)
	kc := infraqa.NewKeycloakService(hc)

	app := freshAppWithCtx()
	app.Get("/r", keycloakRealm(kc))
	resp, _ := app.Test(httptest.NewRequest(fiber.MethodGet, "/r", nil))
	if resp.StatusCode != fiber.StatusBadGateway {
		t.Errorf("status = %d, want 502", resp.StatusCode)
	}
}

// --- keycloakAdminUser handler -------------------------------------------

func TestKeycloakAdminUser_HappyPath(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/token", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"access_token": "t", "expires_in": 3600})
	})
	up.handle("/admin/users/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"id": strings.TrimPrefix(r.URL.Path, "/admin/users/"), "username": "alice",
		})
	})
	hc := buildHTTPClient(t, up.server.URL)
	kc := infraqa.NewKeycloakService(hc)

	app := freshAppWithCtx()
	app.Get("/admin/:id", keycloakAdminUser(kc))

	resp, _ := app.Test(httptest.NewRequest(fiber.MethodGet, "/admin/abc-123", nil))
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != fiber.StatusOK {
		t.Fatalf("status = %d body = %s", resp.StatusCode, body)
	}
}

func TestKeycloakAdminUser_NotFoundMapsTo404(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/token", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"access_token": "t", "expires_in": 3600})
	})
	up.handle("/admin/users/", func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	})
	hc := buildHTTPClient(t, up.server.URL)
	kc := infraqa.NewKeycloakService(hc)

	app := freshAppWithCtx()
	app.Get("/admin/:id", keycloakAdminUser(kc))
	resp, _ := app.Test(httptest.NewRequest(fiber.MethodGet, "/admin/ghost", nil))
	if resp.StatusCode != fiber.StatusNotFound {
		t.Errorf("status = %d, want 404", resp.StatusCode)
	}
}

func TestKeycloakAdminUser_UpstreamErrorReturns502(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/token", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "token-fail", http.StatusInternalServerError)
	})
	hc := buildHTTPClient(t, up.server.URL)
	kc := infraqa.NewKeycloakService(hc)

	app := freshAppWithCtx()
	app.Get("/admin/:id", keycloakAdminUser(kc))
	resp, _ := app.Test(httptest.NewRequest(fiber.MethodGet, "/admin/x", nil))
	if resp.StatusCode != fiber.StatusBadGateway {
		t.Errorf("status = %d, want 502", resp.StatusCode)
	}
}

// --- keycloakTenantWhoami handler ----------------------------------------

func TestKeycloakTenantWhoami_MissingCredentialsReturns400(t *testing.T) {
	up := newFakeUpstream(t)
	hc := buildHTTPClient(t, up.server.URL)
	kc := infraqa.NewKeycloakService(hc)

	app := freshAppWithCtx()
	app.Get("/w", keycloakTenantWhoami(kc))

	resp, _ := app.Test(httptest.NewRequest(fiber.MethodGet, "/w", nil))
	if resp.StatusCode != fiber.StatusBadRequest {
		t.Errorf("missing creds status = %d, want 400", resp.StatusCode)
	}
}

func TestKeycloakTenantWhoami_HappyPath(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/token", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		if r.Form.Get("username") == "" {
			http.Error(w, "no creds", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"access_token": "tnt", "expires_in": 3600})
	})
	up.handle("/userinfo", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"sub":                "alice-sub",
			"preferred_username": "alice",
		})
	})
	hc := buildHTTPClient(t, up.server.URL)
	kc := infraqa.NewKeycloakService(hc)

	app := freshAppWithCtx()
	app.Get("/w", keycloakTenantWhoami(kc))

	resp, _ := app.Test(httptest.NewRequest(fiber.MethodGet, "/w?username=alice&password=secret", nil))
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != fiber.StatusOK {
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"preferred_username":"alice"`) {
		t.Errorf("body should carry whoami payload, got %s", body)
	}
}

// --- showcase handlers ---------------------------------------------------

func TestShowcaseDownloadStream(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/echo/stream/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		_, _ = w.Write([]byte("XXXXXXXXXXXXXXXX"))
	})
	hc := buildHTTPClient(t, up.server.URL)
	echo := infraqa.NewEchoService(hc)

	app := freshAppWithCtx()
	app.Get("/d/:size", showcaseDownloadStream(echo))

	resp, _ := app.Test(httptest.NewRequest(fiber.MethodGet, "/d/16", nil))
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != fiber.StatusOK {
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"bytes":16`) {
		t.Errorf("body should report bytes=16, got %s", body)
	}
}

func TestShowcaseUploadStream(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/echo/upload", func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"received_bytes": len(data), "content_type": r.Header.Get("Content-Type"),
		})
	})
	hc := buildHTTPClient(t, up.server.URL)
	echo := infraqa.NewEchoService(hc)

	app := freshAppWithCtx()
	app.Post("/u", showcaseUploadStream(echo))
	req := httptest.NewRequest(fiber.MethodPost, "/u", strings.NewReader("hello"))
	req.Header.Set("Content-Type", "text/plain")
	resp, _ := app.Test(req)
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != fiber.StatusOK {
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
}

func TestShowcaseMultipart(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/echo/multipart", func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"fields": map[string]string{},
			"files":  []map[string]any{},
		})
	})
	hc := buildHTTPClient(t, up.server.URL)
	echo := infraqa.NewEchoService(hc)
	app := freshAppWithCtx()
	app.Post("/m", showcaseMultipart(echo))

	// Empty body — handler substitutes the "PDF-PLACEHOLDER" default.
	resp, _ := app.Test(httptest.NewRequest(fiber.MethodPost, "/m", nil))
	if resp.StatusCode != fiber.StatusOK {
		t.Errorf("status = %d", resp.StatusCode)
	}
}

func TestShowcaseSSE(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/echo/sse", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		fl, _ := w.(http.Flusher)
		_, _ = w.Write([]byte("event: ping\ndata: 1\n\n"))
		if fl != nil {
			fl.Flush()
		}
	})
	hc := buildHTTPClient(t, up.server.URL)
	echo := infraqa.NewEchoService(hc)
	app := freshAppWithCtx()
	app.Get("/sse", showcaseSSE(echo))

	resp, _ := app.Test(httptest.NewRequest(fiber.MethodGet, "/sse", nil))
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != fiber.StatusOK {
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
}

func TestShowcaseSigned(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/echo/signed", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"observed_at":   "ts",
			"received_body": "{}",
			"x_signature":   r.Header.Get("X-Signature"),
		})
	})
	hc := buildHTTPClient(t, up.server.URL)
	echo := infraqa.NewEchoService(hc)
	app := freshAppWithCtx()
	app.Post("/s", showcaseSigned(echo))
	req := httptest.NewRequest(fiber.MethodPost, "/s", strings.NewReader("{}"))
	req.Header.Set("Content-Type", "application/json")
	resp, _ := app.Test(req)
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != fiber.StatusOK {
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
}

func TestShowcaseWithConfigOverride_DefaultBodyAndEcho(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/echo/upload", func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"received_bytes": len(data), "content_type": r.Header.Get("Content-Type"),
		})
	})
	hc := buildHTTPClient(t, up.server.URL)
	echo := infraqa.NewEchoService(hc)
	app := freshAppWithCtx()
	app.Post("/o", showcaseWithConfigOverride(echo))

	// Empty body — handler substitutes "default-payload".
	resp, _ := app.Test(httptest.NewRequest(fiber.MethodPost, "/o", nil))
	if resp.StatusCode != fiber.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}

	// With a body — handler forwards it.
	resp, _ = app.Test(httptest.NewRequest(fiber.MethodPost, "/o", strings.NewReader("hi")))
	if resp.StatusCode != fiber.StatusOK {
		t.Errorf("status = %d on non-empty body", resp.StatusCode)
	}
}

func TestShowcaseInlineBearer_HappyPath(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/echo/signed", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"observed_at":   "ts",
			"received_body": "",
			"authorization": r.Header.Get("Authorization"),
		})
	})
	hc := buildHTTPClient(t, up.server.URL)
	echo := infraqa.NewEchoService(hc)
	app := freshAppWithCtx()
	app.Post("/ib", showcaseInlineBearer(echo))

	resp, _ := app.Test(httptest.NewRequest(fiber.MethodPost, "/ib?token=my-token", nil))
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != fiber.StatusOK {
		t.Fatalf("status=%d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), "Bearer my-token") {
		t.Errorf("expected Bearer my-token in response, got %s", body)
	}
}

// --- MountShowcase / MountWhoami / MountEcho — exercise the registration paths
// to bump the route-mounting code into coverage.

func TestMountShowcase_RegistersRoutes(t *testing.T) {
	up := newFakeUpstream(t)
	hc := buildHTTPClient(t, up.server.URL)
	kc := infraqa.NewKeycloakService(hc)
	echo := infraqa.NewEchoService(hc)

	app := freshAppWithCtx()
	MountShowcase(app, kc, echo, bootstrap.Deps{})

	// Spot-check one route from each subgroup; their handlers' behavior is
	// already covered above.
	routes := []string{
		"/showcase/keycloak/realm",
		"/showcase/httpclient/download-stream/4",
		"/showcase/httpclient/sse",
	}
	for _, r := range routes {
		resp, _ := app.Test(httptest.NewRequest(fiber.MethodGet, r, nil))
		if resp.StatusCode == fiber.StatusNotFound {
			t.Errorf("MountShowcase did not register %q", r)
		}
	}
}

// Trivial sanity that the application configuration helpers used by handlers
// remain importable from the web layer's test file.
var _ = configuration.LangENG
