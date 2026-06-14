//go:build integration

// Integration tests for the external service adapters. Drive them against a
// fake httptest.Server upstream so we exercise the real httpclient pipeline
// (tag binding, codec, middleware) without depending on a live Keycloak.
//
// Run with: go test -tags=integration ./infra/external/...
package external

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/infra/httpclient"
)

// fakeUpstream wires a single httptest.Server that routes by path. Each test
// installs its own routes via the handler map.
type fakeUpstream struct {
	t       *testing.T
	server  *httptest.Server
	mu      *http.ServeMux
	tokenOK *bool // when non-nil, /token returns this state
}

func newFakeUpstream(t *testing.T) *fakeUpstream {
	t.Helper()
	mu := http.NewServeMux()
	srv := httptest.NewServer(mu)
	t.Cleanup(srv.Close)
	return &fakeUpstream{t: t, server: srv, mu: mu}
}

// tokenEndpoint installs a generic /token endpoint mirroring Keycloak's
// OAuth2 contract: returns {access_token, expires_in}. Optional auth header
// is not validated — tests do not care.
func (f *fakeUpstream) tokenEndpoint(path, accessToken string) {
	f.mu.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token": accessToken,
			"expires_in":   3600,
		})
	})
}

func (f *fakeUpstream) handle(path string, h http.HandlerFunc) {
	f.mu.HandleFunc(path, h)
}

// --- Keycloak service ----------------------------------------------------

func TestKeycloakService_GetRealmInfo(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/realms/test/.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issuer":            "http://" + r.Host + "/realms/test",
			"token_endpoint":    "http://" + r.Host + "/token",
			"jwks_uri":          "http://" + r.Host + "/jwks",
			"scopes_supported":  []string{"openid", "email"},
		})
	})

	hc, err := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"keycloak-public": {
				BaseURL: up.server.URL,
				Endpoints: map[string]httpclient.EndpointConfig{
					"getRealmInfo": {
						Method: "GET",
						Path:   "/realms/test/.well-known/openid-configuration",
					},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("httpclient.New: %v", err)
	}
	svc := NewKeycloakService(hc)

	info, err := svc.GetRealmInfo(context.Background())
	if err != nil {
		t.Fatalf("GetRealmInfo: %v", err)
	}
	if !strings.Contains(info.Issuer, "/realms/test") {
		t.Errorf("issuer = %q", info.Issuer)
	}
	if len(info.ScopesSupported) != 2 {
		t.Errorf("scopes = %v", info.ScopesSupported)
	}
}

func TestKeycloakService_GetRealmInfo_PropagatesError(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/realms/test/.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	})

	hc, _ := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"keycloak-public": {
				BaseURL: up.server.URL,
				Endpoints: map[string]httpclient.EndpointConfig{
					"getRealmInfo": {Method: "GET", Path: "/realms/test/.well-known/openid-configuration"},
				},
			},
		},
	})
	svc := NewKeycloakService(hc)
	if _, err := svc.GetRealmInfo(context.Background()); err == nil {
		t.Error("expected error on 500 upstream")
	}
}

func TestKeycloakService_FetchUser_HappyPath(t *testing.T) {
	up := newFakeUpstream(t)
	up.tokenEndpoint("/realms/test/protocol/openid-connect/token", "kc-token")
	up.handle("/admin/realms/test/users/", func(w http.ResponseWriter, r *http.Request) {
		segs := strings.Split(r.URL.Path, "/")
		id := segs[len(segs)-1]
		auth := r.Header.Get("Authorization")
		if auth != "Bearer kc-token" {
			http.Error(w, "missing bearer", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"id":            id,
			"username":      "alice",
			"email":         "alice@x",
			"emailVerified": true,
			"enabled":       true,
		})
	})

	hc, err := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"keycloak-admin": {
				BaseURL: up.server.URL,
				Auth:    &httpclient.ServiceAuthConfig{Provider: "kc-admin"},
				Endpoints: map[string]httpclient.EndpointConfig{
					"getUser": {
						Method:           "GET",
						Path:             "/admin/realms/test/users/{id}",
						AcceptableStatus: []int{404},
					},
				},
			},
		},
		AuthProviders: map[string]httpclient.AuthProviderConfig{
			"kc-admin": {
				Type:          "oauth2-client-credentials",
				TokenEndpoint: up.server.URL + "/realms/test/protocol/openid-connect/token",
				ClientID:      "client",
				ClientSecret:  "secret",
				TokenCache: &httpclient.TokenCacheConfig{
					Source: "response-field",
					JSONPath: "$.expires_in",
					Unit:   "seconds",
					Skew:   httpclient.Duration(30 * time.Second),
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("httpclient.New: %v", err)
	}
	svc := NewKeycloakService(hc)

	got, err := svc.FetchUser(context.Background(), "abc-123")
	if err != nil {
		t.Fatalf("FetchUser: %v", err)
	}
	if got.ID != "abc-123" || got.Username != "alice" {
		t.Errorf("FetchUser = %+v", got)
	}
}

func TestKeycloakService_FetchUser_404MapsToErrUserNotFound(t *testing.T) {
	up := newFakeUpstream(t)
	up.tokenEndpoint("/realms/test/protocol/openid-connect/token", "kc-token")
	up.handle("/admin/realms/test/users/", func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	})

	hc, _ := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"keycloak-admin": {
				BaseURL: up.server.URL,
				Auth:    &httpclient.ServiceAuthConfig{Provider: "kc-admin"},
				Endpoints: map[string]httpclient.EndpointConfig{
					"getUser": {
						Method:           "GET",
						Path:             "/admin/realms/test/users/{id}",
						AcceptableStatus: []int{404},
					},
				},
			},
		},
		AuthProviders: map[string]httpclient.AuthProviderConfig{
			"kc-admin": {
				Type:          "oauth2-client-credentials",
				TokenEndpoint: up.server.URL + "/realms/test/protocol/openid-connect/token",
				ClientID:      "c",
				ClientSecret:  "s",
				TokenCache: &httpclient.TokenCacheConfig{
					Source: "response-field", JSONPath: "$.expires_in", Unit: "seconds",
					Skew: httpclient.Duration(30 * time.Second),
				},
			},
		},
	})
	svc := NewKeycloakService(hc)

	_, err := svc.FetchUser(context.Background(), "missing")
	if !errors.Is(err, ErrUserNotFound) {
		t.Errorf("expected ErrUserNotFound, got %v", err)
	}
}

func TestKeycloakService_WhoamiTenant_HappyPath(t *testing.T) {
	up := newFakeUpstream(t)
	// Token endpoint accepts the credentials-exchange grant + emits a token.
	up.handle("/realms/test/protocol/openid-connect/token", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		// minimal sanity — credentials come through the body
		if r.Form.Get("username") == "" || r.Form.Get("password") == "" {
			http.Error(w, "missing credentials", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token": "tenant-token",
			"expires_in":   3600,
		})
	})
	up.handle("/realms/test/protocol/openid-connect/userinfo", func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if auth != "Bearer tenant-token" {
			http.Error(w, "missing bearer", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"sub":                "alice-sub",
			"preferred_username": "alice",
			"email":              "alice@x",
		})
	})

	hc, err := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"keycloak-tenant": {
				BaseURL: up.server.URL,
				Auth:    &httpclient.ServiceAuthConfig{Provider: "kc-password-tenant"},
				Endpoints: map[string]httpclient.EndpointConfig{
					"whoami": {
						Method: "GET",
						Path:   "/realms/test/protocol/openid-connect/userinfo",
					},
				},
			},
		},
		AuthProviders: map[string]httpclient.AuthProviderConfig{
			"kc-password-tenant": {
				Type:          "credentials-exchange",
				TokenEndpoint: up.server.URL + "/realms/test/protocol/openid-connect/token",
				RequestCodec:  "form-urlencoded",
				RequestFields: map[string]string{
					"grant_type": "password",
					"client_id":  "c",
					"scope":      "openid",
				},
				RequestFieldsFromCtx: map[string]string{
					"username": "tenant.username",
					"password": "tenant.password",
				},
				ResponseTokenPath: "$.access_token",
				TokenCache: &httpclient.TokenCacheConfig{
					Source: "response-field", JSONPath: "$.expires_in", Unit: "seconds",
					Skew: httpclient.Duration(30 * time.Second),
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("httpclient.New: %v", err)
	}
	svc := NewKeycloakService(hc)

	appCtx := configuration.NewAppContextWithRandomID(configuration.LangENG)
	w, err := svc.WhoamiTenant(appCtx, "alice", "secret")
	if err != nil {
		t.Fatalf("WhoamiTenant: %v", err)
	}
	if w.Subject != "alice-sub" || w.PreferredUsername != "alice" {
		t.Errorf("Whoami = %+v", w)
	}
}

func TestKeycloakService_WhoamiTenant_PropagatesError(t *testing.T) {
	up := newFakeUpstream(t)
	// Token endpoint always rejects.
	up.handle("/realms/test/protocol/openid-connect/token", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "bad credentials", http.StatusUnauthorized)
	})

	hc, _ := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"keycloak-tenant": {
				BaseURL: up.server.URL,
				Auth:    &httpclient.ServiceAuthConfig{Provider: "kc-password-tenant"},
				Endpoints: map[string]httpclient.EndpointConfig{
					"whoami": {Method: "GET", Path: "/userinfo"},
				},
			},
		},
		AuthProviders: map[string]httpclient.AuthProviderConfig{
			"kc-password-tenant": {
				Type:          "credentials-exchange",
				TokenEndpoint: up.server.URL + "/realms/test/protocol/openid-connect/token",
				RequestCodec:  "form-urlencoded",
				RequestFieldsFromCtx: map[string]string{
					"username": "tenant.username", "password": "tenant.password",
				},
				ResponseTokenPath: "$.access_token",
				TokenCache: &httpclient.TokenCacheConfig{
					Source: "response-field", JSONPath: "$.expires_in", Unit: "seconds",
					Skew: httpclient.Duration(30 * time.Second),
				},
			},
		},
	})
	svc := NewKeycloakService(hc)

	appCtx := configuration.NewAppContextWithRandomID(configuration.LangENG)
	if _, err := svc.WhoamiTenant(appCtx, "alice", "wrong"); err == nil {
		t.Error("expected WhoamiTenant to surface upstream rejection")
	}
}

// --- Echo service --------------------------------------------------------

func TestEchoService_DownloadStream(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/echo/stream/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		_, _ = w.Write(bytes.Repeat([]byte{0x41}, 32))
	})

	hc, _ := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"echo": {
				BaseURL: up.server.URL,
				Endpoints: map[string]httpclient.EndpointConfig{
					"download": {
						Method:         "GET",
						Path:           "/echo/stream/{size}",
						ResponseStream: true,
					},
				},
			},
		},
	})
	svc := NewEchoService(hc)
	n, sample, err := svc.DownloadStream(context.Background(), "32")
	if err != nil {
		t.Fatalf("DownloadStream: %v", err)
	}
	if n != 32 {
		t.Errorf("bytes = %d, want 32", n)
	}
	if !strings.HasPrefix(sample, "AAAA") {
		t.Errorf("sample = %q", sample)
	}
}

func TestEchoService_UploadStream(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/echo/upload", func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"received_bytes": len(data),
			"content_type":   r.Header.Get("Content-Type"),
		})
	})

	hc, _ := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"echo": {
				BaseURL: up.server.URL,
				Endpoints: map[string]httpclient.EndpointConfig{
					"uploadStream": {Method: "POST", Path: "/echo/upload"},
				},
			},
		},
	})
	svc := NewEchoService(hc)
	r, err := svc.UploadStream(context.Background(), strings.NewReader("hello"), "text/plain")
	if err != nil {
		t.Fatalf("UploadStream: %v", err)
	}
	if r.ReceivedBytes != 5 || r.ContentType != "text/plain" {
		t.Errorf("UploadStream response = %+v", r)
	}
}

func TestEchoService_UploadStream_DefaultsContentType(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/echo/upload", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"received_bytes": 0,
			"content_type":   r.Header.Get("Content-Type"),
		})
	})

	hc, _ := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"echo": {
				BaseURL: up.server.URL,
				Endpoints: map[string]httpclient.EndpointConfig{
					"uploadStream": {Method: "POST", Path: "/echo/upload"},
				},
			},
		},
	})
	svc := NewEchoService(hc)
	r, err := svc.UploadStream(context.Background(), strings.NewReader(""), "")
	if err != nil {
		t.Fatalf("UploadStream: %v", err)
	}
	if r.ContentType != "application/octet-stream" {
		t.Errorf("default Content-Type = %q", r.ContentType)
	}
}

func TestEchoService_UploadMultipart(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/echo/multipart", func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		fields := map[string]string{}
		for k, vs := range r.MultipartForm.Value {
			if len(vs) > 0 {
				fields[k] = vs[0]
			}
		}
		files := []map[string]any{}
		for name, fs := range r.MultipartForm.File {
			for _, fh := range fs {
				files = append(files, map[string]any{
					"name":     name,
					"filename": fh.Filename,
					"mime":     fh.Header.Get("Content-Type"),
					"size":     fh.Size,
				})
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"fields": fields,
			"files":  files,
		})
	})

	hc, _ := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"echo": {
				BaseURL: up.server.URL,
				Endpoints: map[string]httpclient.EndpointConfig{
					"multipart": {Method: "POST", Path: "/echo/multipart"},
				},
			},
		},
	})
	svc := NewEchoService(hc)

	r, err := svc.UploadMultipart(context.Background(),
		[]httpclient.MultipartField{{Name: "category", Value: "doc"}},
		[]httpclient.MultipartFile{{
			Name: "file", Filename: "p.pdf", MimeType: "application/pdf",
			Content: bytes.NewReader([]byte("PDF-DATA")),
		}})
	if err != nil {
		t.Fatalf("UploadMultipart: %v", err)
	}
	if r.Fields["category"] != "doc" {
		t.Errorf("fields = %+v", r.Fields)
	}
	if len(r.Files) != 1 || r.Files[0].Filename != "p.pdf" {
		t.Errorf("files = %+v", r.Files)
	}
}

func TestEchoService_SignedRoundTrip(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/echo/signed", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"observed_at":     "ts",
			"received_bytes":  len(body),
			"received_body":   string(body),
			"x_date":          r.Header.Get("X-Date"),
			"x_content_sha":   r.Header.Get("X-Content-SHA256"),
			"x_signature":     r.Header.Get("X-Signature"),
			"x_key_id":        r.Header.Get("X-Key-Id"),
			"authorization":   r.Header.Get("Authorization"),
		})
	})

	hc, err := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"echo-signed": {
				BaseURL: up.server.URL,
				Signing: &httpclient.SigningConfig{
					Type:                "hmac-sha256",
					KeyId:               "kid-1",
					KeyIdHeader:         "X-Key-Id",
					Secret:              "shh",
					SignedHeaders:       []string{"host", "x-date", "x-content-sha256"},
					TimestampHeader:     "X-Date",
					ContentSHA256Header: "X-Content-SHA256",
					SignatureHeader:     "X-Signature",
				},
				Endpoints: map[string]httpclient.EndpointConfig{
					"signed": {Method: "POST", Path: "/echo/signed"},
				},
			},
		},
	})
	if err != nil {
		t.Fatalf("httpclient.New: %v", err)
	}
	svc := NewEchoService(hc)
	resp, err := svc.SignedRoundTrip(context.Background(), map[string]string{"hello": "world"})
	if err != nil {
		t.Fatalf("SignedRoundTrip: %v", err)
	}
	if resp.XSignature == "" {
		t.Error("expected X-Signature populated")
	}
	if resp.XDate == "" || resp.XContentSHA == "" || resp.XKeyID != "kid-1" {
		t.Errorf("signed headers missing: %+v", resp)
	}
}

func TestEchoService_WithConfigOverride(t *testing.T) {
	up := newFakeUpstream(t)
	got := make(chan string, 1)
	up.handle("/echo/upload", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		got <- string(body)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"received_bytes": len(body),
			"content_type":   r.Header.Get("Content-Type"),
		})
	})

	hc, _ := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"echo": {
				BaseURL: up.server.URL,
				Endpoints: map[string]httpclient.EndpointConfig{
					// uploadStream declared as a streaming endpoint; the override
					// switches it to json body via CallConfig.Method+Path.
					"uploadStream": {
						Method: "POST",
						Path:   "/wrong",
					},
				},
			},
		},
	})
	svc := NewEchoService(hc)

	r, err := svc.WithConfigOverride(context.Background(), "hi")
	if err != nil {
		t.Fatalf("WithConfigOverride: %v", err)
	}
	if r.ReceivedBytes == 0 {
		t.Error("expected non-zero received bytes")
	}
	select {
	case body := <-got:
		if !strings.Contains(body, `"payload":"hi"`) {
			t.Errorf("upstream observed body = %q", body)
		}
	case <-time.After(time.Second):
		t.Fatal("upstream did not capture the request body")
	}
}

func TestEchoService_InlineBearerRoundTrip(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/echo/signed", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"observed_at":   "ts",
			"received_body": "",
			"authorization": r.Header.Get("Authorization"),
		})
	})

	hc, _ := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"echo-signed": {
				BaseURL: up.server.URL,
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
	})
	svc := NewEchoService(hc)

	r, err := svc.InlineBearerRoundTrip(context.Background(), "tok-42", "{}")
	if err != nil {
		t.Fatalf("InlineBearerRoundTrip: %v", err)
	}
	if r.Authorization != "Bearer tok-42" {
		t.Errorf("Authorization = %q, want Bearer tok-42", r.Authorization)
	}
}

func TestEchoService_InlineBearerRoundTrip_EmptyTokenFallsBackToDefault(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/echo/signed", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"observed_at":   "ts",
			"received_body": "",
			"authorization": r.Header.Get("Authorization"),
		})
	})

	hc, _ := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"echo-signed": {
				BaseURL: up.server.URL,
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
	})
	svc := NewEchoService(hc)
	r, err := svc.InlineBearerRoundTrip(context.Background(), "   ", "{}")
	if err != nil {
		t.Fatalf("InlineBearerRoundTrip: %v", err)
	}
	if !strings.HasPrefix(r.Authorization, "Bearer demo-bearer-token") {
		t.Errorf("expected fallback bearer 'demo-bearer-token', got %q", r.Authorization)
	}
}

// --- SubscribeEvents ------------------------------------------------------

func TestEchoService_SubscribeEvents_ReceivesAndTerminates(t *testing.T) {
	up := newFakeUpstream(t)
	up.handle("/echo/sse", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		flusher, _ := w.(http.Flusher)
		fmt.Fprintf(w, "event: tick\nid: 1\ndata: hello\n\n")
		flusher.Flush()
		fmt.Fprintf(w, "event: tick\nid: 2\ndata: world\n\n")
		flusher.Flush()
		// Close stream to make the consumer's channel finish.
	})

	hc, _ := httpclient.New(&httpclient.Config{
		Services: map[string]httpclient.ServiceConfig{
			"echo": {
				BaseURL: up.server.URL,
				Endpoints: map[string]httpclient.EndpointConfig{
					"sse": {Method: "GET", Path: "/echo/sse", ResponseSSE: true},
				},
			},
		},
	})
	svc := NewEchoService(hc)
	events, err := svc.SubscribeEvents(context.Background())
	if err != nil {
		t.Fatalf("SubscribeEvents: %v", err)
	}
	if len(events) < 2 {
		t.Errorf("expected at least 2 events, got %d (%+v)", len(events), events)
	}
}

// --- Constructor helpers --------------------------------------------------

func TestNewKeycloakService_NonNil(t *testing.T) {
	hc, _ := httpclient.New(&httpclient.Config{Services: map[string]httpclient.ServiceConfig{}})
	if NewKeycloakService(hc) == nil {
		t.Error("NewKeycloakService should return non-nil")
	}
}

func TestNewEchoService_NonNil(t *testing.T) {
	hc, _ := httpclient.New(&httpclient.Config{Services: map[string]httpclient.ServiceConfig{}})
	if NewEchoService(hc) == nil {
		t.Error("NewEchoService should return non-nil")
	}
}
