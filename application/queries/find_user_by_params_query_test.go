package queries

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

func TestFindUserByParamsQuery_ToCriteriaIsIdentity(t *testing.T) {
	want := fwqueries.ReadCriteria{
		Filter:          map[string]any{"name": "Jane", "email": map[string]any{"$in": []any{"a@x.com"}}},
		Limit:           20,
		Sort:            []fwqueries.SortField{{Field: "name", Desc: true}},
		IncludeArchived: true,
	}
	q := FindUserByParamsQuery{Criteria: want}
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	got := q.ToCriteria(ctx)

	if got.Limit != 20 || !got.IncludeArchived {
		t.Errorf("scalar fields not preserved: %+v", got)
	}
	if got.Filter["name"] != "Jane" {
		t.Errorf("filter[name] not preserved: %v", got.Filter["name"])
	}
	if len(got.Sort) != 1 || got.Sort[0].Field != "name" || !got.Sort[0].Desc {
		t.Errorf("sort not preserved: %+v", got.Sort)
	}
}
