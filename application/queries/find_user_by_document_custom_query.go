package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindUserByDocumentQuery is the by-document lookup transport for the manual
// showcase under /showcase/users-custom/:document. Internally it becomes a
// single-item ReadPage with Filter[Document]=<value>; the framework's
// canonical FindByIDQueryHandler dispatches to ViewReader.ReadByID which only
// knows the document's primary-key path (Mongo's _id). Switching the public
// identifier from UUID to the Person natural key (document) is the whole
// motivation of going manual on the read side — and it landed without changing
// the Mongo view because UserView already merges the shared Person fields
// (including document) flat into the user document.
//
// ToCriteria(ctx) carries the AppContext-derived overlays (future tenant id,
// owner id) on top of the document filter — Query is the only layer that may
// consume ctx on the read side.
type FindUserByDocumentQuery struct {
	pipeline.QueryBase
	Document        string
	IncludeArchived bool
}

func (q FindUserByDocumentQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return fwqueries.ReadCriteria{
		Filter:          map[string]any{"Document": q.Document},
		Limit:           1,
		IncludeArchived: q.IncludeArchived,
	}, nil
}
