package main

import (
	"github.com/ClaudioSchirmer/omnicore/bootstrap"

	appinfra "github.com/ClaudioSchirmer/omnicore-example-users/internal/infra"
	appweb "github.com/ClaudioSchirmer/omnicore-example-users/internal/web"

	"github.com/gofiber/fiber/v3"
)

// UserCustomFeature mounts the manual (hand-written) command/query chain over
// the User aggregate under /showcase/users-custom/*. This is BUSINESS surface,
// not a framework fixture: it is a second, explicit way to operate the very
// same User aggregate the canonical UsersFeature drives through the Auto
// handlers — the side-by-side comparison of "framework does it for you" vs
// "here is every step by hand" over one real business entity. It therefore
// ships in the canonical binary alongside User/Employee.
//
// Only framework-exercise fixtures that are unrelated to the business (the
// Gadget mirror aggregate, whoami, echo, keycloak and cache showcases) live
// under //go:build qa in the qafixtures/ subpackages.
//
// The concrete *appinfra.UserCustomRepository is built here over the shared
// relational engine (Deps.DB), so it persists to the same `users` table the
// canonical UsersFeature writes to. The User aggregate needs no domain service
// (the SharedBase write path enforces identity), so the manual handlers receive
// a nil service — tolerated by the framework when the entity requires none.
type UserCustomFeature struct {
	customRepo *appinfra.UserCustomRepository
}

// NewUserCustomFeature builds the manual showcase Repository over the shared
// relational engine. customRepo is backend-neutral: it takes the relational
// engine (Deps.DB) directly, so swapping the SQL backend is a YAML dialect
// change with no edit here.
func NewUserCustomFeature(d bootstrap.Deps) *UserCustomFeature {
	return &UserCustomFeature{customRepo: appinfra.NewUserCustomRepository(d.DB)}
}

// Mount satisfies bootstrap.Feature — registers /showcase/users-custom/* via
// the single entry point in web/. The concrete repo is converted to the
// appcmd.ScopedUserRepository port at the call boundary; the service is nil.
func (f *UserCustomFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	appweb.MountUsersCustom(app, f.customRepo, nil, d)
}
