package infra

import (
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/domain"
	fwinfra "github.com/ClaudioSchirmer/omnicore/infra"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// UserRepository is a canonical aggregate-aware Repository: embeds
// fwinfra.BaseAggregateRepository[*User], which itself bundles:
//
//   - BaseRepository[*User]: Insert/Update/Archive/Unarchive/Delete + New()
//     via factory. Unique violations (PG 23505) become typed notifications
//     via the Constraints map.
//   - *AggregateLoader[*User]: FindByID/FindArchivedByID via auto-scan
//     (reflection over the exported fields of *User and *Address). Children
//     registered via fwinfra.WithChild[V](r.Loader).
//
// ContextName not declared — derived from the Go type T via TypeName[T](),
// default "User". Override only for custom magic patterns (legacy / two Repos
// on the same aggregate).
type UserRepository struct {
	fwinfra.BaseAggregateRepository[*appdomain.User]
}

func NewUserRepository(pg *fwinfra.Postgres) *UserRepository {
	r := &UserRepository{
		BaseAggregateRepository: fwinfra.NewBaseAggregateRepository[*appdomain.User](
			pg,
			func() *appdomain.User { return &appdomain.User{} },
		),
	}
	r.Constraints = map[string]fwinfra.ConstraintBinding{
		"users_email_active_idx": {Notification: appdomain.EmailAlreadyExistsNotification{}, Field: "email"},
	}
	fwinfra.WithChild[appdomain.Address](r.Loader)
	return r
}

var (
	_ persistence.ScopedRepository[*appdomain.User] = (*UserRepository)(nil)
	_ domain.ArchivedFinder[*appdomain.User]        = (*UserRepository)(nil)
)
