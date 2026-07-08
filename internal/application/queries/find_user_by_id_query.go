package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindUserByIDQuery is the application-side transport for a by-id user read.
// QueryByIDBase supplies SetPathID (called by the wrapper from the URL
// segment) + GetID consumed by the framework's FindByIDQueryHandler.
// ContextName returns "User" so the 404 NotificationContext aligns with the
// identity the write side emits (Insert/Update/Delete notifications carry
// the same "User" context), instead of the plural collection name "users".
//
// ToCriteria(ctx) is the only layer below the web boundary that may consume
// *AppContext — JWT-derived overlays (tenant id, owner id) layer onto the
// returned ReadCriteria here. The handler forwards the criteria to
// ViewReader.ReadByID, which merges Filter into the {_id: id} +
// deleted_at gate; Limit/Sort/After/Before/Search/Projection are ignored
// by ReadByID by design (they only make sense on a paged read).
type FindUserByIDQuery struct {
	fwqueries.QueryByIDBase
	IncludeArchived bool
}

func (q FindUserByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return fwqueries.ReadCriteria{IncludeArchived: q.IncludeArchived}, nil
}
func (q FindUserByIDQuery) ContextName() string { return "User" }
