package requests

import "testing"

func TestFindAddressByIDRequest_ToQuery_HappyPath(t *testing.T) {
	r := FindAddressByIDRequest{AddressID: "a-1"}
	q := r.ToQuery()
	if q.AddressID != "a-1" {
		t.Errorf("AddressID mismatch: got %q", q.AddressID)
	}
	if q.IncludeArchived {
		t.Error("expected IncludeArchived=false by default")
	}
}

func TestFindAddressByIDRequest_ToQuery_IncludeArchivedTrue(t *testing.T) {
	flag := true
	r := FindAddressByIDRequest{AddressID: "a-1", IncludeArchived: &flag}
	q := r.ToQuery()
	if !q.IncludeArchived {
		t.Error("expected IncludeArchived=true from request")
	}
}
