// Package external holds the outbound HTTP service structs that wrap
// per-vendor httpclient calls. Application handlers depend on the types
// in this package and never import omnicore/infra/httpclient directly —
// swapping HTTP for gRPC or a fake never touches application/.
//
// Each file in this package targets one external system. The structs
// concentrate the transport tags, the call surface, and the mapping from
// vendor DTOs to neutral projections. The framework's CLAUDE.md describes
// the pattern under "Composition pattern (consumer side)".
package external

import (
	"context"
	"errors"
	"fmt"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/infra/httpclient"
)

// KeycloakService talks to the local Keycloak fixture. Exposes
// business-vocabulary methods (GetRealmInfo, FetchUser, WhoamiTenant)
// that the application/handlers/ layer consumes. Per the framework's
// composition pattern, handlers depend on *KeycloakService and never
// import httpclient.
type KeycloakService struct {
	http *httpclient.HttpClient
}

// NewKeycloakService builds the service over the shared HttpClient
// registry. UsersFeature constructs it once at boot and injects it into
// the handlers that need it.
func NewKeycloakService(http *httpclient.HttpClient) *KeycloakService {
	return &KeycloakService{http: http}
}

// --- DTOs (transport-only, package-private) ------------------------------

// realmInfoRequest is empty — the OIDC discovery endpoint takes no
// parameters. Declared as a struct anyway because Call's generic
// signature requires a request type.
type realmInfoRequest struct{}

// RealmInfo is the neutral projection of the OIDC discovery document.
// Only the fields the consumers need are extracted; the upstream emits
// many more.
type RealmInfo struct {
	Issuer                string   `json:"issuer"`
	TokenEndpoint         string   `json:"token_endpoint"`
	AuthorizationEndpoint string   `json:"authorization_endpoint"`
	UserinfoEndpoint      string   `json:"userinfo_endpoint"`
	JWKSURI               string   `json:"jwks_uri"`
	ScopesSupported       []string `json:"scopes_supported"`
}

// fetchUserRequest carries the {id} path parameter for the Keycloak
// admin user-fetch endpoint.
type fetchUserRequest struct {
	ID string `http:"path,id"`
}

// KeycloakUser is the neutral projection of an admin-fetched user.
// Mirrors the fields a typical consumer would surface; the upstream
// emits credentials, federated identities, group mappings etc. that
// are intentionally NOT lifted here.
type KeycloakUser struct {
	ID            string `json:"id"`
	Username      string `json:"username"`
	Email         string `json:"email"`
	EmailVerified bool   `json:"emailVerified"`
	FirstName     string `json:"firstName"`
	LastName      string `json:"lastName"`
	Enabled       bool   `json:"enabled"`
}

// whoamiRequest is empty — userinfo takes no body, only the bearer token
// applied by the per-call credentials-exchange provider.
type whoamiRequest struct{}

// Whoami is the userinfo projection. Subject is the only field
// guaranteed by RFC 7662; consumers typically need more (preferred
// username, email) and we expose them.
type Whoami struct {
	Subject           string `json:"sub"`
	PreferredUsername string `json:"preferred_username"`
	Email             string `json:"email"`
	GivenName         string `json:"given_name"`
	FamilyName        string `json:"family_name"`
}

// ErrUserNotFound is the domain-shaped error returned when the upstream
// reports 404 on getUser. Distinct from a transport failure so the
// handler can branch cleanly.
var ErrUserNotFound = errors.New("keycloak: user not found")

// --- methods -------------------------------------------------------------

// GetRealmInfo fetches the OIDC discovery document. Anonymous endpoint;
// the framework caches the response per the endpoint's TTL.
func (s *KeycloakService) GetRealmInfo(ctx context.Context) (RealmInfo, error) {
	info, err := httpclient.Call[realmInfoRequest, RealmInfo](
		ctx, s.http, "keycloak-public", "getRealmInfo", realmInfoRequest{},
	)
	if err != nil {
		return RealmInfo{}, fmt.Errorf("keycloak realm info: %w", err)
	}
	return info, nil
}

// FetchUser hits the Keycloak admin API for the given user id. Uses
// oauth2-client-credentials transparently (the YAML wires kc-admin). A
// 404 from the upstream is mapped to ErrUserNotFound; consumers branch
// on errors.Is.
func (s *KeycloakService) FetchUser(ctx context.Context, id string) (KeycloakUser, error) {
	user, err := httpclient.Call[fetchUserRequest, KeycloakUser](
		ctx, s.http, "keycloak-admin", "getUser",
		fetchUserRequest{ID: id},
	)
	switch {
	case httpclient.IsAcceptableStatus(err, 404):
		return KeycloakUser{}, ErrUserNotFound
	case err != nil:
		return KeycloakUser{}, fmt.Errorf("keycloak fetch user %q: %w", id, err)
	}
	return user, nil
}

// WhoamiTenant exercises the credentials-exchange provider with
// requestFieldsFromCtx. The caller must populate tenant.username and
// tenant.password on the AppContext before invoking; the framework
// resolves them at acquire time and caches the token per tenant
// (SHA-256 identity hash).
func (s *KeycloakService) WhoamiTenant(ctx *configuration.AppContext, username, password string) (Whoami, error) {
	ctx.Set("tenant.username", username)
	ctx.Set("tenant.password", password)
	resp, err := httpclient.Call[whoamiRequest, Whoami](
		ctx, s.http, "keycloak-tenant", "whoami", whoamiRequest{},
	)
	if err != nil {
		return Whoami{}, fmt.Errorf("keycloak whoami: %w", err)
	}
	return resp, nil
}
