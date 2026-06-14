// Package handlers holds the manual application-layer handlers consumed by
// the /showcase/users-custom/* showcase. Each handler implements
// pipeline.Handler[*Cmd, TRes] explicitly — the canonical /users/* surface
// reuses the framework's generic handlers in omnicore/application/handlers
// (InsertCommandHandler, UpdateCommandHandler, etc.), which hide the
// FindByID → Get* → Writer.Method(ctx, valid, opts...) → SetID dance
// behind a type signature. Writing the chain by hand is the whole point of
// the showcase: it documents what the canonical wrappers do under the cover.
package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/persistence"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// UserCustomRepository is the application-layer port the manual handlers
// depend on. Extends persistence.Writer[*User] (the write surface
// carrying the lifecycle-hook variadic) with the email-keyed lookups the
// framework primitives do not expose (FindByID/FindArchivedByID only
// know the primary-key path). The concrete implementation lives in
// infra/user_custom_repository.go and is wired by ShowcaseFeature.
//
// Declaring this interface here — instead of importing the concrete
// *appinfra.UserCustomRepository — keeps the dependency direction
// application → domain (and application → application/persistence), never
// application → infra. Same rule the canonical Auto handlers honor
// (they depend on persistence.Writer[T] alone).
type UserCustomRepository interface {
	persistence.Writer[*appdomain.User]
	FindByEmail(email string) (*appdomain.User, error)
	FindArchivedByEmail(email string) (*appdomain.User, error)
}
