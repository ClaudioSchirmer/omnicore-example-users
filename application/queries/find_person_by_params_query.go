package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindPersonByParamsQuery is the application-side transport for a paged read
// of the all-in-one person view (the SharedBaseView over the shared Person
// identity). The wrapper has already parsed the query string into the embedded
// ReadCriteria; ToCriteria(ctx) is where identity-derived overlays would layer
// on — none here.
type FindPersonByParamsQuery struct {
	pipeline.QueryBase
	Criteria fwqueries.ReadCriteria
}

func (q FindPersonByParamsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}
