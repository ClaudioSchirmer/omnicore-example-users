package main

import (
	"github.com/ClaudioSchirmer/omnicore/bootstrap"

	appinfra "github.com/ClaudioSchirmer/omnicore-example-users/infra"
	appexternal "github.com/ClaudioSchirmer/omnicore-example-users/infra/external"
	appweb "github.com/ClaudioSchirmer/omnicore-example-users/web"

	"github.com/gofiber/fiber/v3"
)

// ShowcaseFeature mounts every framework-exercise route under a single
// context so the User aggregate's feature stays focused on user CRUD.
// Four Mount entry points are called:
//
//	appweb.MountWhoami      → GET /whoami (auth identity demo)
//	appweb.MountShowcase    → /showcase/keycloak/* + /showcase/httpclient/*
//	appweb.MountEcho        → /echo/* in-process upstream for the
//	                           /showcase/httpclient/* demos
//	appweb.MountUsersCustom → /showcase/users-custom/* manual chain over
//	                           the User aggregate (write side — read side
//	                           arrives in a follow-up)
//
// The feature does not contribute a view to the SyncEngine — implements
// bootstrap.Feature only (no Views method). The KeycloakService and
// EchoService are constructed over the shared HttpClient registry the
// framework exposes on bootstrap.Deps; the custom repo + service for the
// users-custom showcase are constructed over the shared relational engine
// (Deps.DB) so the surface persists to the same `users` table the canonical
// UsersFeature writes to — both routes exercising the same aggregate is the
// whole point of the side-by-side comparison.
//
// Splitting showcase from UsersFeature keeps the canonical example
// (UsersFeature) free of demo routes that would otherwise dilute the
// "one aggregate, one feature" pattern documented in CLAUDE.md.
type ShowcaseFeature struct {
	kc         *appexternal.KeycloakService
	echo       *appexternal.EchoService
	customRepo *appinfra.UserCustomRepository
	customSvc  *appinfra.UserService
}

// NewShowcaseFeature builds the outbound adapters over the shared
// HttpClient and the manual showcase Repository + Service over the shared
// relational engine. The duplicate UserService instance (UsersFeature already
// constructs one) is intentional and cheap: UserService is stateless and
// the alternative — threading it across features — would couple
// ShowcaseFeature to UsersFeature, breaking the bootstrap.Feature contract.
func NewShowcaseFeature(d bootstrap.Deps) *ShowcaseFeature {
	// customRepo + customSvc are backend-neutral: they take the relational
	// engine (Deps.DB) directly, so swapping the SQL backend is a YAML dialect
	// change with no edit here.
	return &ShowcaseFeature{
		kc:         appexternal.NewKeycloakService(d.HttpClient),
		echo:       appexternal.NewEchoService(d.HttpClient),
		customRepo: appinfra.NewUserCustomRepository(d.DB),
		customSvc:  appinfra.NewUserService(d.DB),
	}
}

// Mount satisfies bootstrap.Feature — registers the framework-exercise
// routes via four thin entry points in web/. /echo/* is the upstream
// of /showcase/httpclient/* so MountEcho lands in the same Fiber app;
// MountUsersCustom lives next to the other showcases so /showcase/* is
// the visual prefix for "demos" across the surface.
func (f *ShowcaseFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	appweb.MountWhoami(app, d)
	appweb.MountEcho(app, d)
	appweb.MountShowcase(app, f.kc, f.echo, d)
	appweb.MountUsersCustom(app, f.customRepo, f.customSvc, d)
	// /showcase/cache/* — minimal CRUD over Deps.Cache (private) and
	// Deps.SharedCache (shared) so qa/cache.sh can drive the framework's
	// cache subsystem end to end. Hidden in the OpenAPI spec because it's
	// a QA fixture, not a production surface.
	appweb.MountCacheShowcase(app, d)
}
