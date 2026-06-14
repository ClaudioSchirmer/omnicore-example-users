package requests

import (
	"testing"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

func TestFindAddressByEmailAndIDRequest_ToQuery_HappyPath(t *testing.T) {
	r := FindAddressByEmailAndIDRequest{Email: "jane@example.com", AddressID: "a-1"}
	q := r.ToQuery(fwqueries.ReadCriteria{})
	if q.Email != "jane@example.com" || q.AddressID != "a-1" {
		t.Errorf("path fields not transferred: %+v", q)
	}
	if q.IncludeArchived {
		t.Error("expected IncludeArchived=false by default")
	}
}

func TestFindAddressByEmailAndIDRequest_ToQuery_ArchivedPropagates(t *testing.T) {
	r := FindAddressByEmailAndIDRequest{Email: "jane@example.com", AddressID: "a-1"}
	q := r.ToQuery(fwqueries.ReadCriteria{IncludeArchived: true})
	if !q.IncludeArchived {
		t.Error("expected IncludeArchived=true from criteria")
	}
}

