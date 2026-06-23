package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindAddressByEmailAndIDQuery is the manual showcase twin of
// FindAddressByIDQuery. Same projection — one address sub-document of one
// User view doc — exposed under
// /showcase/users-custom/:email/addresses/:addressId. The route resolves
// the parent via Email (Filter[Email]=<value> + Limit:1 ReadPage), then
// walks the embedded addresses[] for the matching ID, matching the
// canonical handler's shape.
//
// QueryBase (not QueryBaseWithID) — the manual chain assembles the
// Query inline from the Request DTO's path-tagged fields; no SetPathID
// auto-bind is involved.
type FindAddressByEmailAndIDQuery struct {
	pipeline.QueryBase
	Email           string
	AddressID       string
	IncludeArchived bool
}

func (q FindAddressByEmailAndIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return fwqueries.ReadCriteria{
		Filter:          map[string]any{"Email": q.Email},
		Limit:           1,
		IncludeArchived: q.IncludeArchived,
	}, nil
}
