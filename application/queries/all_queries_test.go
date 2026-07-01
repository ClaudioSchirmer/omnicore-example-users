package queries

import (
	"testing"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

func TestFindUserByDocumentQuery_ToCriteria(t *testing.T) {
	q := FindUserByDocumentQuery{Document: "alice@x", IncludeArchived: true}
	crit, _ := q.ToCriteria(nil)
	if crit.Filter["Document"] != "alice@x" {
		t.Errorf("Filter[Email] = %v, want alice@x", crit.Filter["Document"])
	}
	if crit.Limit != 1 {
		t.Errorf("Limit = %d, want 1", crit.Limit)
	}
	if !crit.IncludeArchived {
		t.Error("IncludeArchived should propagate")
	}
}

func TestFindUserByDocumentQuery_ActiveOnlyByDefault(t *testing.T) {
	q := FindUserByDocumentQuery{Document: "x@y"}
	crit, _ := q.ToCriteria(nil)
	if crit.IncludeArchived {
		t.Error("default ToCriteria should NOT include archived")
	}
}

func TestFindUsersCustomQuery_ToCriteria_PassthroughOfCriteria(t *testing.T) {
	want := fwqueries.ReadCriteria{
		Filter:          map[string]any{"name": "Alice"},
		Limit:           10,
		IncludeArchived: true,
	}
	got, _ := FindUsersCustomQuery{Criteria: want}.ToCriteria(nil)
	if got.Limit != 10 || !got.IncludeArchived || got.Filter["name"] != "Alice" {
		t.Errorf("ToCriteria did not preserve Criteria, got %+v", got)
	}
}

func TestFindAddressByIDQuery_ToCriteria(t *testing.T) {
	q := FindAddressByIDQuery{IncludeArchived: true}
	crit, _ := q.ToCriteria(nil)
	if !crit.IncludeArchived {
		t.Error("IncludeArchived flag should propagate as IncludeArchived")
	}
	if crit.Filter != nil {
		t.Errorf("expected nil Filter, got %v", crit.Filter)
	}
}

func TestFindAddressByIDQuery_ContextName(t *testing.T) {
	if got := (FindAddressByIDQuery{}).ContextName(); got != "Address" {
		t.Errorf("ContextName = %q, want Address", got)
	}
}

func TestFindAddressByDocumentAndIDQuery_ToCriteria(t *testing.T) {
	q := FindAddressByDocumentAndIDQuery{
		Document:        "owner@x",
		AddressID:       "addr-1",
		IncludeArchived: true,
	}
	crit, _ := q.ToCriteria(nil)
	if crit.Filter["Document"] != "owner@x" {
		t.Errorf("Filter[Email] = %v", crit.Filter["Document"])
	}
	if crit.Limit != 1 {
		t.Errorf("Limit = %d, want 1", crit.Limit)
	}
	if !crit.IncludeArchived {
		t.Error("IncludeArchived should propagate")
	}
}

func TestFindAddressByDocumentAndIDQuery_ActiveOnlyByDefault(t *testing.T) {
	q := FindAddressByDocumentAndIDQuery{Document: "x@y", AddressID: "id"}
	crit, _ := q.ToCriteria(nil)
	if crit.IncludeArchived {
		t.Error("default should not include archived")
	}
}
