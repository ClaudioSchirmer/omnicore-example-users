package infra

import (
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/read"
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/write"
	"github.com/ClaudioSchirmer/omnicore/infra/db/core"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// UserRepository is the role repository for the User aggregate, which is backed
// by a SharedBase (the Person identity). It embeds
// read.SharedBaseRoleRepository[*User] — the aggregate repository PLUS the
// persistence.SharedBaseInsertLoader[*User] capability the SharedBase upsert
// insert needs (load-by-natural-key of the existing identity + its base
// children before a POST).
//
// The capability marries this repository to handlers.SharedBaseInsertCommandHandler:
// the plain InsertCommandHandler refuses a SharedBase-backed repo, and this
// handler refuses a non-SharedBase one. WithSchema asserts UserSchema() actually
// declares a SharedBase.
type UserRepository struct {
	read.SharedBaseRoleRepository[*appdomain.User]
}

func NewUserRepository(eng core.RelationalEngine) *UserRepository {
	r := &UserRepository{
		SharedBaseRoleRepository: read.NewSharedBaseRoleRepository[*appdomain.User](
			eng,
			func() *appdomain.User { return &appdomain.User{} },
		),
	}
	// The happy-path 409 (POST for a person who already has an active user)
	// comes from the framework's SharedBase write matrix directly
	// (EntityAlreadyAddedNotification). This constraint binding is the
	// concurrency safety net: two simultaneous POSTs for the same new document
	// race past the existence probe and one loses on the PRIMARY KEY (shared-PK:
	// users.id == persons.id) — map that violation to the SAME 409 notification for
	// a consistent envelope. Postgres names the PK `users_pkey`; MySQL reports the
	// colliding key as `PRIMARY`.
	r.Constraints = map[string]write.ConstraintBinding{
		"users_pkey": {Notification: domain.EntityAlreadyAddedNotification{}, Field: "id"},
		"PRIMARY":    {Notification: domain.EntityAlreadyAddedNotification{}, Field: "id"},
	}
	r.WithSchema(UserSchema())
	return r
}

var (
	_ persistence.ScopedRepository[*appdomain.User]       = (*UserRepository)(nil)
	_ persistence.SharedBaseInsertLoader[*appdomain.User] = (*UserRepository)(nil)
	_ domain.ArchivedFinder[*appdomain.User]              = (*UserRepository)(nil)
)
