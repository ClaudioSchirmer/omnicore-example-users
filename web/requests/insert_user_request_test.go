package requests

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
)

func TestInsertUserRequest_ToCommand_Minimal(t *testing.T) {
	r := InsertUserRequest{Name: "Alice", Email: "alice@x.com"}
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

func TestInsertUserRequest_ToCommand_Full(t *testing.T) {
	r := InsertUserRequest{
		Name:  "Bob",
		Email: "bob@x.com",
		Phone: strptr("11999999999"),
		Addresses: []AddressRequest{
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

func TestInsertUserRequest_ToCommand_PhoneEmptyStringPreserved(t *testing.T) {
	// Phase 21: 1:1 assignment. Consumer sent "" → Request stores *"" →
	// Command receives *"" (no NilIfEmpty).
	empty := ""
	r := InsertUserRequest{Name: "x", Email: "y@z.w", Phone: &empty}
	cmd := r.ToCommand()
	if cmd.Phone == nil || *cmd.Phone != "" {
		t.Errorf("expected *'', got %v", cmd.Phone)
	}
}

func TestInsertUserRequest_ToCommand_EmptyAddressesSlice(t *testing.T) {
	r := InsertUserRequest{Name: "x", Email: "y@z.w", Addresses: []AddressRequest{}}
	cmd := r.ToCommand()
	if cmd.Addresses == nil {
		t.Errorf("expected non-nil empty slice")
	}
	if len(cmd.Addresses) != 0 {
		t.Errorf("expected 0 addresses")
	}
}

// ─── Output: FromResult ──────────────────────────────────────────────────────

func TestInsertUserResponse_FromResult(t *testing.T) {
	id := domain.NewRandomID()
	phone := "11999999999"
	r := commands.InsertUserResult{ID: id, Name: "Alice", Email: "a@x.com", Phone: &phone}

	resp := InsertUserResponse{}.FromResult(r)

	if resp.ID != id {
		t.Errorf("ID mismatch: got %v, want %v", resp.ID, id)
	}
	if resp.Name != "Alice" || resp.Email != "a@x.com" {
		t.Errorf("scalar fields not transferred: %+v", resp)
	}
	if resp.Phone == nil || *resp.Phone != "11999999999" {
		t.Errorf("Phone not transferred: %v", resp.Phone)
	}
}

func TestInsertUserResponse_FromResult_NilPhoneOmitted(t *testing.T) {
	resp := InsertUserResponse{}.FromResult(commands.InsertUserResult{
		ID: domain.NewRandomID(), Name: "x", Email: "y@z.w",
	})
	if resp.Phone != nil {
		t.Errorf("expected nil Phone, got %v", resp.Phone)
	}
}
