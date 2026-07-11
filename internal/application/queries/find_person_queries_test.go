package queries

import (
	"testing"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

func TestFindPersonsByParamsQuery_ToCriteria_Passthrough(t *testing.T) {
	want := fwqueries.ReadCriteria{
		Filter:          map[string]any{"Name": "Ana", "User.UserName": "ana"},
		Limit:           10,
		Search:          "souza",
		IncludeArchived: true,
	}
	got, err := FindPersonsByParamsQuery{Criteria: want}.ToCriteria(nil)
	if err != nil {
		t.Fatalf("ToCriteria: %v", err)
	}
	if got.Limit != 10 || !got.IncludeArchived || got.Search != "souza" ||
		got.Filter["Name"] != "Ana" || got.Filter["User.UserName"] != "ana" {
		t.Errorf("ToCriteria did not preserve Criteria, got %+v", got)
	}
}

func TestFindPersonByIDQuery_ToCriteria(t *testing.T) {
	crit, err := FindPersonByIDQuery{IncludeArchived: true}.ToCriteria(nil)
	if err != nil {
		t.Fatalf("ToCriteria: %v", err)
	}
	if !crit.IncludeArchived {
		t.Error("IncludeArchived should propagate")
	}
	crit, _ = FindPersonByIDQuery{}.ToCriteria(nil)
	if crit.IncludeArchived {
		t.Error("default ToCriteria should NOT include archived")
	}
}

func TestFindPersonByIDQuery_ContextName(t *testing.T) {
	if got := (FindPersonByIDQuery{}).ContextName(); got != "Person" {
		t.Errorf("ContextName = %q, want Person", got)
	}
}
