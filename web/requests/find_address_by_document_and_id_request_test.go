package requests

import (
	"testing"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

func TestFindAddressByDocumentAndIDRequest_ToQuery_HappyPath(t *testing.T) {
	r := FindAddressByDocumentAndIDRequest{Document: "jane@example.com", AddressID: "a-1"}
	q := r.ToQuery(fwqueries.ReadCriteria{})
	if q.Document != "jane@example.com" || q.AddressID != "a-1" {
		t.Errorf("path fields not transferred: %+v", q)
	}
	if q.IncludeArchived {
		t.Error("expected IncludeArchived=false by default")
	}
}

func TestFindAddressByDocumentAndIDRequest_ToQuery_ArchivedPropagates(t *testing.T) {
	r := FindAddressByDocumentAndIDRequest{Document: "jane@example.com", AddressID: "a-1"}
	q := r.ToQuery(fwqueries.ReadCriteria{IncludeArchived: true})
	if !q.IncludeArchived {
		t.Error("expected IncludeArchived=true from criteria")
	}
}
