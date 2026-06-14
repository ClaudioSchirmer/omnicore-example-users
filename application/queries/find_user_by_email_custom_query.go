package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindUserByEmailQuery is the by-email lookup transport for the manual
// showcase under /showcase/users-custom/:email. Internally it becomes a
// single-item ReadPage with Filter[email]=<value>; the framework's
// canonical FindByIDQueryHandler dispatches to ViewReader.ReadByID which
// only knows the document's primary-key path (Mongo's _id). Switching the
// public identifier from UUID to email is the whole motivation of going
// manual on the read side — and it landed without changing the Mongo view
// because UserView already denormalizes the root's email into the
// document.
//
// ToCriteria(ctx) carries the AppContext-derived overlays (future tenant
// id, owner id) on top of the email filter — Query is the only layer that
// may consume ctx on the read side.
type FindUserByEmailQuery struct {
	pipeline.QueryBase
	Email           string
	IncludeArchived bool
}

func (q FindUserByEmailQuery) ToCriteria(_ *configuration.AppContext) fwqueries.ReadCriteria {
	return fwqueries.ReadCriteria{
		Filter:          map[string]any{"email": q.Email},
		Limit:           1,
		IncludeArchived: q.IncludeArchived,
	}
}
