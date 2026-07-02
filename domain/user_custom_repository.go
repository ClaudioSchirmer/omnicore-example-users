package domain

import (
	"github.com/ClaudioSchirmer/omnicore/domain"
)

// UserCustomRepository is the read+write repository PORT for the manual
// showcase surface (/showcase/users-custom/*) over the User aggregate — a
// DOMAIN concept, declared here so the application layer depends on a domain
// interface, never on infra. The name mirrors the infra adapter that
// implements it (infra.UserCustomRepository) and marks it as the
// manual-showcase counterpart to the canonical /users/* path, which uses the
// framework's generic persistence.ScopedRepository directly and needs no
// example-domain port.
//
// It composes the framework's pure repository ports (domain.Repository[*User]
// = Reader[*User] + Writer, both ctx-free) with the document-keyed lookups the
// by-id contract does not cover. Document is the Person natural key — the
// stable, human-meaningful handle this surface uses in place of the opaque id.
//
// Pure: it imports only the framework's domain package — no application, no
// context, no actor. The request scope (ctx + lifecycle hooks) is bound BELOW
// this port: the infra adapter (infra.UserCustomRepository) exposes a Scope
// method that returns a value satisfying this interface with its write methods
// already bound to the request's *AppContext. Handlers receive that scoped
// value and call the pure read+write methods directly.
type UserCustomRepository interface {
	domain.Repository[*User]
	FindByDocument(document string) (*User, error)
	FindArchivedByDocument(document string) (*User, error)
}
