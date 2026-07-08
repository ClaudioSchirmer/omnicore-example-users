package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindEmployeeByParamsQuery is the application-side transport for a paged
// employee read. The wrapper has already parsed the query string into the
// embedded ReadCriteria; ToCriteria(ctx) is where identity-derived overlays
// would layer on — none here (the field-level Restrict showcase lives on the
// User surface).
type FindEmployeeByParamsQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindEmployeeByParamsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}
