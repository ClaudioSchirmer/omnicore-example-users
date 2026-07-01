package requests

import (
	"testing"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

func TestFindUserByDocumentCustomRequest_ToQuery_DefaultsArchivedFalse(t *testing.T) {
	r := FindUserByDocumentCustomRequest{Document: "jane@example.com"}
	q := r.ToQuery(fwqueries.ReadCriteria{})
	if q.Document != "jane@example.com" {
		t.Errorf("expected email=jane@example.com, got %q", q.Document)
	}
	if q.IncludeArchived {
		t.Error("expected IncludeArchived=false by default")
	}
}

func TestFindUserByDocumentCustomRequest_ToQuery_IncludeArchivedFromCriteria(t *testing.T) {
	r := FindUserByDocumentCustomRequest{Document: "bob@example.com"}
	q := r.ToQuery(fwqueries.ReadCriteria{IncludeArchived: true})
	if !q.IncludeArchived {
		t.Error("expected IncludeArchived=true from criteria")
	}
}
