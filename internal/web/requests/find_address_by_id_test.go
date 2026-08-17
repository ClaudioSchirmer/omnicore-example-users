package requests

import (
	"testing"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
)

func TestFindAddressByIDRequest_ToQuery_HappyPath(t *testing.T) {
	r := FindAddressByIDRequest{AddressID: "a-1"}
	q := r.ToQuery(fwqueries.ReadCriteria{})
	if q.AddressID != "a-1" {
		t.Errorf("AddressID mismatch: got %q", q.AddressID)
	}
	if q.Criteria.IncludeArchived {
		t.Error("expected IncludeArchived=false by default")
	}
}

func TestFindAddressByIDRequest_ToQuery_IncludeArchivedTrue(t *testing.T) {
	r := FindAddressByIDRequest{AddressID: "a-1"}
	q := r.ToQuery(fwqueries.ReadCriteria{IncludeArchived: true})
	if !q.Criteria.IncludeArchived {
		t.Error("expected IncludeArchived=true from the wire criteria")
	}
}
