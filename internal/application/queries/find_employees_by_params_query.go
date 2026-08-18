package queries

import (
	"time"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindEmployeesByParamsQuery is the application-side transport for a paged
// employee read. The wrapper has already parsed the query string into the
// embedded ReadCriteria; ToCriteria(ctx) is where identity-derived overlays
// would layer on — none here (the field-level Restrict showcase lives on the
// User surface).
type FindEmployeesByParamsQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindEmployeesByParamsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

// FromQueryResult is the mandatory read-side projection hook — the twin of a
// command's FromEntity. The framework fills one Result per document; this
// listing needs no computation.
func (q FindEmployeesByParamsQuery) FromQueryResult(_ *configuration.AppContext, r FindEmployeesByParamsResult) (FindEmployeesByParamsResult, error) {
	return r, nil
}

// ─── RESULT ─────────────────────────────────────────────────────────────────

// FindEmployeesByParamsResult is the application-layer Result of one Employee
// view document. Tagless; every field a pointer or slice because the endpoint
// opts into `?fields=` (the framework boot-guards the sparse contract). The
// shared Person fields and the bank sibling sit FLAT at the root, exactly as
// the composer stores them.
type FindEmployeesByParamsResult struct {
	ID             *string
	Name           *string
	Email          *string
	Phone          *string
	Document       *string
	Ethnicity      *string
	EmployeeNumber *string
	Bank           *string
	Branch         *string
	Account        *string
	Pix            *string

	Addresses    []FindUsersByParamsAddressResult
	Dependents   []DependentResult
	JobHistories []JobHistoryResult
}

// DependentResult is the Result shape of one Dependent child — the
// health-plan sibling's fields render FLAT in the same object, mirroring the
// flat Go child.
type DependentResult struct {
	ID                 *string
	Name               *string
	BirthDate          *time.Time
	Relationship       *string
	HealthPlanProvider *string
	HealthPlanCard     *string
	HealthPlanExpiry   *time.Time
	HealthPlanType     *string
}

// JobHistoryResult is the Result shape of one JobHistory child.
type JobHistoryResult struct {
	ID           *string
	JobTitle     *string
	Department   *string
	HiredAt      *time.Time
	TerminatedAt *time.Time
}
