package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindPersonsByParamsQuery is the application-side transport for a paged read
// of the all-in-one person view (the SharedBaseView over the shared Person
// identity). The wrapper has already parsed the query string into the embedded
// ReadCriteria; ToCriteria(ctx) is where identity-derived overlays would layer
// on — none here.
type FindPersonsByParamsQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindPersonsByParamsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}
