package main

import (
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	fwgraphql "github.com/ClaudioSchirmer/omnicore/web/graphql"

	appinfra "github.com/ClaudioSchirmer/omnicore-example-users/infra"
	appweb "github.com/ClaudioSchirmer/omnicore-example-users/web"

	"github.com/gofiber/fiber/v3"
)

// UsersFeature bundles the User aggregate's repo + view and mounts the
// /users/* routes. Implements bootstrap.ReadableFeature (has a read side —
// contributes the users view to the SyncEngine).
//
// User needs NO domain service: identity uniqueness is enforced by the
// SharedBase write path (the deterministic id UUIDv5(document) makes a
// duplicate document collide; a duplicate active role collides on the
// role's PRIMARY KEY (shared-PK: users.id == persons.id)), so RequiresService()
// stays at its default (false) and
// the handlers receive a nil service — tolerated by the framework when the
// entity requires none.
//
// This feature is intentionally focused on the User aggregate. Framework
// showcases (Keycloak demos, httpclient streaming/signing/CallConfig
// demos, the /echo/* upstream, /whoami) live in ShowcaseFeature so the
// canonical "one aggregate, one feature, one Mount" pattern stays clean.
type UsersFeature struct {
	repo *appinfra.UserRepository
	view *query.ViewDefinition
}

// NewUsersFeature builds the feature's singletons exactly once: the
// repository over the shared relational engine and the declarative view.
// UserView() is called here — its single call site.
func NewUsersFeature(d bootstrap.Deps) *UsersFeature {
	// repo is backend-neutral: it takes the relational engine (Deps.DB)
	// directly, so swapping the SQL backend is a YAML dialect change with no
	// edit here.
	return &UsersFeature{
		repo: appinfra.NewUserRepository(d.DB),
		view: appinfra.UserView(),
	}
}

// Views satisfies bootstrap.ReadableFeature.
func (f *UsersFeature) Views() []*query.ViewDefinition {
	return []*query.ViewDefinition{f.view}
}

// Mount satisfies bootstrap.Feature — delegates HTTP registration to the
// web/ package. bootstrap/ is composition; web/ remains the owner of the
// routes. Only /users/* are registered here; the showcase + /echo/ +
// /whoami routes are mounted by ShowcaseFeature.
func (f *UsersFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	appweb.MountUsers(app, f.repo, nil, f.view, d)
}

// MountGraphQL contributes the User aggregate's fields to the service's single
// GraphQL registry — the GraphQL twin of Mount. The registry is created once in
// Wire (the single /graphql surface); each feature adds its fields cumulatively,
// reusing the same repo/service/view this feature already holds (no second
// construction). web owns the field attachment (appweb.MountUsersGraphQL).
func (f *UsersFeature) MountGraphQL(reg *fwgraphql.Registry, d bootstrap.Deps) {
	appweb.MountUsersGraphQL(reg, f.repo, nil, f.view, d)
}
