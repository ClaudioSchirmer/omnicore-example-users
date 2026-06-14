package requests

import (
	"testing"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

func TestFindUserByEmailCustomRequest_ToQuery_DefaultsArchivedFalse(t *testing.T) {
	r := FindUserByEmailCustomRequest{Email: "jane@example.com"}
	q := r.ToQuery(fwqueries.ReadCriteria{})
	if q.Email != "jane@example.com" {
		t.Errorf("expected email=jane@example.com, got %q", q.Email)
	}
	if q.IncludeArchived {
		t.Error("expected IncludeArchived=false by default")
	}
}

func TestFindUserByEmailCustomRequest_ToQuery_IncludeArchivedFromCriteria(t *testing.T) {
	r := FindUserByEmailCustomRequest{Email: "bob@example.com"}
	q := r.ToQuery(fwqueries.ReadCriteria{IncludeArchived: true})
	if !q.IncludeArchived {
		t.Error("expected IncludeArchived=true from criteria")
	}
}

