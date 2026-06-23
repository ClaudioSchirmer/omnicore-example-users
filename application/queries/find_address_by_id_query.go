package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindAddressByIDQuery is the application-side transport for the canonical
// GET /users/:id/addresses/:addressId. The User UUID arrives via the
// wrapper's `:id` auto-bind (populated by HandleQueryWithID into
// QueryBaseWithID.SetPathID); the Address UUID arrives via the Request
// DTO's `path:"addressId"` tag and is forwarded by ToQuery.
//
// Embedding QueryBaseWithID makes the Query satisfy the framework's
// FindByIDQuery interface (GetID/SetPathID + ContextName + ToCriteria), so
// it plugs into HandleQueryWithIDSpec alongside any other by-id route —
// only the handler diverges from the Auto FindByIDQueryHandler because
// this read returns a SUB-document (one address inside the user view),
// not the root.
type FindAddressByIDQuery struct {
	fwqueries.QueryBaseWithID
	AddressID       string
	IncludeArchived bool
}

func (q FindAddressByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return fwqueries.ReadCriteria{IncludeArchived: q.IncludeArchived}, nil
}

// ContextName aligns the 404 NotificationContext with the entity the
// missing row belongs to. The custom handler emits NotFound on either
// "User" (parent doc absent) or "Address" (parent present but address id
// not in the embedded array); ContextName returns "Address" here so the
// happy 404 (the typical client mistake — sending a wrong address id)
// carries the natural identity. The user-missing branch emits its own
// "User" context explicitly inside the handler.
func (q FindAddressByIDQuery) ContextName() string { return "Address" }
