package requests

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

func TestFindUsersCustomRequest_ToQuery_PassesCriteriaThrough(t *testing.T) {
	r := FindUsersCustomRequest{}
	crit := fwqueries.ReadCriteria{
		Filter:          map[string]any{"name": "Jane"},
		Limit:           20,
		IncludeArchived: true,
	}
	q := r.ToQuery(crit)
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	got, _ := q.ToCriteria(ctx)
	if got.Filter["name"] != "Jane" || got.Limit != 20 || !got.IncludeArchived {
		t.Errorf("criteria not carried through ToQuery: %+v", got)
	}
}
