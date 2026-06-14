package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindUserByParamsQuery is the application-side transport for a paged user
// read. The wrapper HandleQueryWithParams has already parsed the query
// string into the embedded ReadCriteria; ToCriteria(ctx) returns it
// verbatim today.
//
// Future JWT integration layers AppContext-derived filters (tenant id, user
// id) inside ToCriteria — the Query is the only layer below the web
// boundary that may consume ctx, and the criteria is what reaches the
// ViewReader, so security overlays belong here.
type FindUserByParamsQuery struct {
	pipeline.QueryBase
	Criteria fwqueries.ReadCriteria
}

func (q FindUserByParamsQuery) ToCriteria(_ *configuration.AppContext) fwqueries.ReadCriteria {
	return q.Criteria
}
