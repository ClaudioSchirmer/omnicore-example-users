package infra

import (
	"context"

	"github.com/ClaudioSchirmer/omnicore/domain"
	fwinfra "github.com/ClaudioSchirmer/omnicore/infra"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// UserService implements appdomain.UserService. Today only EmailExists —
// consulted by User.BuildRules as defense in depth over the partial unique
// index `users_email_active_idx`.
//
// Embeds domain.ServiceBase (the framework's sealed marker interface).
//
// On context: BuildRules does not receive a ctx (domain signature), so the
// service uses context.Background() internally. For granular
// cancellation/timeout in a real scenario, the alternative would be to carry
// the ctx via a field set by middleware before Dispatch — overhead that this
// example doesn't justify (the query is sub-millisecond and the index covers).
type UserService struct {
	domain.ServiceBase
	pg *fwinfra.Postgres
}

func NewUserService(pg *fwinfra.Postgres) *UserService {
	return &UserService{pg: pg}
}

// EmailExists returns true when there is an active row (deleted_at IS NULL)
// with the given email and an ID different from excludeID. excludeID is nil
// on Insert (no ID yet); on Update, it receives *u.GetID() to avoid a false
// positive when the email was not changed.
//
// The `deleted_at IS NULL` filter matches the partial unique index — emails
// reused after archive don't trigger a false positive.
func (s *UserService) EmailExists(email string, excludeID *domain.ID) bool {
	ctx := context.Background()

	var exists bool
	if excludeID == nil || excludeID.IsEmpty() {
		err := s.pg.Pool().QueryRow(ctx,
			`SELECT EXISTS(SELECT 1 FROM users WHERE email = $1 AND deleted_at IS NULL)`,
			email,
		).Scan(&exists)
		if err != nil {
			// I/O failure — return false and let the DB unique index reject at
			// COMMIT. Defensive: don't block a request because of a transient
			// incident in the validation query.
			return false
		}
		return exists
	}

	err := s.pg.Pool().QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM users WHERE email = $1 AND id <> $2 AND deleted_at IS NULL)`,
		email, excludeID.Value(),
	).Scan(&exists)
	if err != nil {
		return false
	}
	return exists
}

// Compile-time check: UserService satisfies the interface declared in domain.
var _ appdomain.UserService = (*UserService)(nil)
