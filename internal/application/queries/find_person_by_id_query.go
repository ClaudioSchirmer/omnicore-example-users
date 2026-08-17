package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindPersonByIDQuery is the application-side transport for a by-id read of
// the all-in-one person view. The id is the shared identity's deterministic
// key (UUIDv5(document)) — the same value the shared-ID roles carry as their
// own id, so a user id or a same-person employee id both resolve the person
// document. ContextName returns "Person" so the 404 NotificationContext names
// the identity, not the collection.
type FindPersonByIDQuery struct {
	fwqueries.QueryByIDBase
	Criteria fwqueries.ReadCriteria
}

func (q FindPersonByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

// FromQueryResult is the mandatory read-side projection hook — the twin of a
// command's FromEntity. Nothing to compute on this read.
func (q FindPersonByIDQuery) FromQueryResult(_ *configuration.AppContext, r FindPersonByIDResult) (FindPersonByIDResult, error) {
	return r, nil
}

func (q FindPersonByIDQuery) ContextName() string { return "Person" }

// ─── RESULT ─────────────────────────────────────────────────────────────────

// FindPersonByIDResult is the application-layer Result of the by-id person
// read — the same segments as one list item, non-sparse at the root (the
// endpoint declares no `?fields=`). Role segments stay pointers so an absent
// role reconstructs as absent, not as a zero-valued object.
type FindPersonByIDResult struct {
	ID        string
	Name      string
	Email     string
	Phone     *string
	Document  string
	Ethnicity string

	Addresses []AddressResult
	User      *PersonUserResult
	Employee  *PersonEmployeeResult
}
