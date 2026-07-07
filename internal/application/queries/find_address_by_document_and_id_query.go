package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindAddressByDocumentAndIDQuery is the manual showcase twin of
// FindAddressByIDQuery. Same projection — one address sub-document of one
// User view doc — exposed under
// /showcase/users-custom/:document/addresses/:addressId. The route resolves
// the parent via Document (Filter[Document]=<value> + Limit:1 ReadPage), then
// walks the embedded addresses[] for the matching ID, matching the
// canonical handler's shape.
//
// QueryBase (not QueryByIDBase) — the manual chain assembles the
// Query inline from the Request DTO's path-tagged fields; no SetPathID
// auto-bind is involved.
type FindAddressByDocumentAndIDQuery struct {
	pipeline.QueryBase
	Document        string
	AddressID       string
	IncludeArchived bool
}

func (q FindAddressByDocumentAndIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return fwqueries.ReadCriteria{
		Filter:          map[string]any{"Document": q.Document},
		Limit:           1,
		IncludeArchived: q.IncludeArchived,
	}, nil
}
