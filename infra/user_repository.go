package infra

import (
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/read"
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/write"
	"github.com/ClaudioSchirmer/omnicore/infra/db/core"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// UserRepository is a canonical aggregate-aware Repository: embeds
// read.BaseAggregateRepository[*User], which itself bundles:
//
//   - BaseRepository[*User]: Insert/Update/Archive/Unarchive/Delete + New()
//     via factory. Unique violations (classified by the engine's Dialect)
//     become typed notifications via the Constraints map.
//   - *AggregateLoader[*User]: FindByID/FindArchivedByID via auto-scan driven
//     by the explicit UserSchema() (root + Address child). WithSchema threads
//     the same map into the write binding, the criteria engine, and the scan.
//
// ContextName not declared — derived from the Go type T via TypeName[T](),
// default "User". Override only for custom magic patterns (legacy / two Repos
// on the same aggregate).
type UserRepository struct {
	read.BaseAggregateRepository[*appdomain.User]
}

func NewUserRepository(eng core.RelationalEngine) *UserRepository {
	r := &UserRepository{
		BaseAggregateRepository: read.NewBaseAggregateRepository[*appdomain.User](
			eng,
			func() *appdomain.User { return &appdomain.User{} },
		),
	}
	r.Constraints = map[string]write.ConstraintBinding{
		"users_email_active_idx": {Notification: appdomain.EmailAlreadyExistsNotification{}, Field: "email"},
	}
	r.WithSchema(UserSchema())
	return r
}

var (
	_ persistence.ScopedRepository[*appdomain.User] = (*UserRepository)(nil)
	_ domain.ArchivedFinder[*appdomain.User]        = (*UserRepository)(nil)
)
