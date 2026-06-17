// Package handlers holds the manual application-layer handlers consumed by
// the /showcase/users-custom/* showcase. Each handler implements
// pipeline.Handler[*Cmd, TRes] explicitly — the canonical /users/* surface
// reuses the framework's generic handlers in omnicore/application/handlers
// (InsertCommandHandler, UpdateCommandHandler, etc.), which hide the
// FindByID → Get* → repo.Scope(ctx).Method(valid) → SetID dance behind a
// type signature. Writing the chain by hand is the whole point of the
// showcase: it documents what the canonical wrappers do under the cover.
package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// ScopedUserRepository is the application-layer scoping provider the manual
// handlers hold. Its single method binds the request scope (ctx + the
// optional in-TX lifecycle hooks) and returns the pure domain read+write
// port appdomain.UserCustomRepository, ready to use — reads and writes both run
// on the returned value.
//
// The repository PORT itself is a domain concept (appdomain.UserCustomRepository in
// domain/user_custom_repository.go). This provider is the binding seam: it lives in
// the application layer because Scope pronounces *configuration.AppContext
// and persistence.WriteOption — both application types the handler (also
// application) consumes freely. The concrete implementation lives in
// infra/user_custom_repository.go and is wired by ShowcaseFeature.
type ScopedUserRepository interface {
	Scope(ctx *configuration.AppContext, opts ...persistence.WriteOption[*appdomain.User]) appdomain.UserCustomRepository
}
