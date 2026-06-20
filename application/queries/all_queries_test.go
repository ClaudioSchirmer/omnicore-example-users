package queries

import (
	"testing"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

func TestFindUserByEmailQuery_ToCriteria(t *testing.T) {
	q := FindUserByEmailQuery{Email: "alice@x", IncludeArchived: true}
	crit := q.ToCriteria(nil)
	if crit.Filter["Email"] != "alice@x" {
		t.Errorf("Filter[Email] = %v, want alice@x", crit.Filter["Email"])
	}
	if crit.Limit != 1 {
		t.Errorf("Limit = %d, want 1", crit.Limit)
	}
	if !crit.IncludeArchived {
		t.Error("IncludeArchived should propagate")
	}
}

func TestFindUserByEmailQuery_ActiveOnlyByDefault(t *testing.T) {
	q := FindUserByEmailQuery{Email: "x@y"}
	if q.ToCriteria(nil).IncludeArchived {
		t.Error("default ToCriteria should NOT include archived")
	}
}

func TestFindUsersCustomQuery_ToCriteria_PassthroughOfCriteria(t *testing.T) {
	want := fwqueries.ReadCriteria{
		Filter:          map[string]any{"name": "Alice"},
		Limit:           10,
		IncludeArchived: true,
	}
	got := FindUsersCustomQuery{Criteria: want}.ToCriteria(nil)
	if got.Limit != 10 || !got.IncludeArchived || got.Filter["name"] != "Alice" {
		t.Errorf("ToCriteria did not preserve Criteria, got %+v", got)
	}
}

func TestFindAddressByIDQuery_ToCriteria(t *testing.T) {
	q := FindAddressByIDQuery{IncludeArchived: true}
	if !q.ToCriteria(nil).IncludeArchived {
		t.Error("IncludeArchived flag should propagate as IncludeArchived")
	}
	if q.ToCriteria(nil).Filter != nil {
		t.Errorf("expected nil Filter, got %v", q.ToCriteria(nil).Filter)
	}
}

func TestFindAddressByIDQuery_ContextName(t *testing.T) {
	if got := (FindAddressByIDQuery{}).ContextName(); got != "Address" {
		t.Errorf("ContextName = %q, want Address", got)
	}
}

func TestFindAddressByEmailAndIDQuery_ToCriteria(t *testing.T) {
	q := FindAddressByEmailAndIDQuery{
		Email:           "owner@x",
		AddressID:       "addr-1",
		IncludeArchived: true,
	}
	crit := q.ToCriteria(nil)
	if crit.Filter["Email"] != "owner@x" {
		t.Errorf("Filter[Email] = %v", crit.Filter["Email"])
	}
	if crit.Limit != 1 {
		t.Errorf("Limit = %d, want 1", crit.Limit)
	}
	if !crit.IncludeArchived {
		t.Error("IncludeArchived should propagate")
	}
}

func TestFindAddressByEmailAndIDQuery_ActiveOnlyByDefault(t *testing.T) {
	q := FindAddressByEmailAndIDQuery{Email: "x@y", AddressID: "id"}
	if q.ToCriteria(nil).IncludeArchived {
		t.Error("default should not include archived")
	}
}
