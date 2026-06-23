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
