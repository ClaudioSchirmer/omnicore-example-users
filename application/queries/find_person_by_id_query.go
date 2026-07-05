package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindPersonByIDQuery is the application-side transport for a by-id read of
// the all-in-one person view. The id is the shared identity's deterministic
// key (UUIDv5(document)) — the same value the shared-PK roles carry as their
// own id, so a user id or a same-person employee id both resolve the person
// document. ContextName returns "Person" so the 404 NotificationContext names
// the identity, not the collection.
type FindPersonByIDQuery struct {
	fwqueries.QueryBaseWithID
	IncludeArchived bool
}

func (q FindPersonByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return fwqueries.ReadCriteria{IncludeArchived: q.IncludeArchived}, nil
}
func (q FindPersonByIDQuery) ContextName() string { return "Person" }
