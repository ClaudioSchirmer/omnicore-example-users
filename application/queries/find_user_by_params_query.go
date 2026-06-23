package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

// FindUserByParamsQuery is the application-side transport for a paged user
// read. The wrapper HandleQueryWithParams has already parsed the query string
// into the embedded ReadCriteria; ToCriteria(ctx) then applies identity-derived
// overlays — the Query is the only layer below the web boundary that may consume
// ctx, and the criteria is what reaches the ViewReader, so security belongs here.
type FindUserByParamsQuery struct {
	pipeline.QueryBase
	Criteria fwqueries.ReadCriteria
}

// ToCriteria showcases field-level read access: Phone is restricted to
// principals carrying users:admin. Restrict removes the field from the read
// (projection + sort + filter), so it surfaces in neither the JSON nor the
// CSV/XLSX export for a non-admin; an active reference (?sort=phone /
// ?fields=phone) returns 403. Dev-safe: under auth-disabled dev the Identity is
// nil and everyone is trusted, so Phone is not restricted there.
func (q FindUserByParamsQuery) ToCriteria(ctx *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	crit := q.Criteria
	if id := ctx.Identity(); id != nil && !id.HasPermission("users:admin") {
		if err := crit.Restrict("Phone"); err != nil {
			return crit, err
		}
	}
	return crit, nil
}
