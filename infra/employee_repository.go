package infra

import (
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/read"
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/write"
	"github.com/ClaudioSchirmer/omnicore/infra/db/core"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// EmployeeRepository is the role repository for the Employee aggregate —
// the SECOND role backed by the SAME Person SharedBase as UserRepository.
// Same shape: read.SharedBaseRoleRepository provides the
// load-by-natural-key capability the SharedBase upsert insert needs, and
// WithSchema registers this role on the engine-scoped registry keyed by the
// persons table, so the refcount/lifecycle probes see users AND employees
// without any consumer-side singleton.
type EmployeeRepository struct {
	read.SharedBaseRoleRepository[*appdomain.Employee]
}

func NewEmployeeRepository(eng core.RelationalEngine) *EmployeeRepository {
	r := &EmployeeRepository{
		SharedBaseRoleRepository: read.NewSharedBaseRoleRepository[*appdomain.Employee](
			eng,
			func() *appdomain.Employee { return &appdomain.Employee{} },
		),
	}
	// Concurrency safety net, mirroring UserRepository: two simultaneous POSTs
	// for the same new document race past the existence probe and one loses on
	// the PRIMARY KEY (shared-PK: employees.id == persons.id) — map that to
	// the same 409 the happy-path conflict emits. Postgres names the PK
	// `employees_pkey`; MySQL reports the colliding key as `PRIMARY`.
	r.Constraints = map[string]write.ConstraintBinding{
		"employees_pkey": {Notification: domain.EntityAlreadyAddedNotification{}, Field: "id"},
		"PRIMARY":        {Notification: domain.EntityAlreadyAddedNotification{}, Field: "id"},
	}
	r.WithSchema(EmployeeSchema())
	return r
}

var (
	_ persistence.ScopedRepository[*appdomain.Employee]       = (*EmployeeRepository)(nil)
	_ persistence.SharedBaseInsertLoader[*appdomain.Employee] = (*EmployeeRepository)(nil)
	_ domain.ArchivedFinder[*appdomain.Employee]              = (*EmployeeRepository)(nil)
)
