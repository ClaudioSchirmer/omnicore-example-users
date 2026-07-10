package requests

import (
	"testing"
)

func TestInsertUserCustomRequest_ToCommand_Minimal(t *testing.T) {
	r := InsertUserCustomRequest{Name: "Alice", Email: "alice@x.com"}
	cmd := r.ToCommand()

	if cmd.Name != "Alice" {
		t.Errorf("Name mismatch: %q", cmd.Name)
	}
	if cmd.Email != "alice@x.com" {
		t.Errorf("Email mismatch: %q", cmd.Email)
	}
	if cmd.Phone != nil {
		t.Errorf("expected Phone=nil, got %v", cmd.Phone)
	}
	if len(cmd.Addresses) != 0 {
		t.Errorf("expected 0 addresses, got %d", len(cmd.Addresses))
	}
}

func TestInsertUserCustomRequest_ToCommand_Full(t *testing.T) {
	r := InsertUserCustomRequest{
		Name:  "Bob",
		Email: "bob@x.com",
		Phone: strptr("11999999999"),
		Addresses: []AddressCustomRequest{
			{Street: "S1", Number: "1", Neighborhood: "N", City: "C", State: "ST", ZipCode: "12345", Country: "US"},
			{Street: "S2", Number: "2", Neighborhood: "N", City: "C", State: "ST", ZipCode: "67890", Country: "US"},
		},
	}
	cmd := r.ToCommand()

	if cmd.Phone == nil || *cmd.Phone != "11999999999" {
		t.Errorf("Phone not transferred: %v", cmd.Phone)
	}
	if len(cmd.Addresses) != 2 {
		t.Fatalf("expected 2 addresses, got %d", len(cmd.Addresses))
	}
	if cmd.Addresses[0].ZipCode != "12345" || cmd.Addresses[1].ZipCode != "67890" {
		t.Errorf("address order/content wrong: %+v", cmd.Addresses)
	}
}

func TestInsertUserCustomRequest_ToCommand_PhoneEmptyStringPreserved(t *testing.T) {
	empty := ""
	r := InsertUserCustomRequest{Name: "x", Email: "y@z.w", Phone: &empty}
	cmd := r.ToCommand()
	if cmd.Phone == nil || *cmd.Phone != "" {
		t.Errorf("expected *'', got %v", cmd.Phone)
	}
}

func TestInsertUserCustomRequest_ToCommand_EmptyAddressesSlice(t *testing.T) {
	r := InsertUserCustomRequest{Name: "x", Email: "y@z.w", Addresses: []AddressCustomRequest{}}
	cmd := r.ToCommand()
	if cmd.Addresses == nil {
		t.Errorf("expected non-nil empty slice")
	}
	if len(cmd.Addresses) != 0 {
		t.Errorf("expected 0 addresses")
	}
}
