package requests

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
)

func TestUpdateUserRequest_ToCommand_Full(t *testing.T) {
	r := UpdateUserRequest{
		Name:  "Bob",
		Email: "bob@x.com",
		Phone: strptr("11999999999"),
		Addresses: []AddressRequest{
			{Street: "S1", Number: "1", Neighborhood: "N", City: "C", State: "ST", ZipCode: "12345", Country: "US"},
		},
	}
	cmd := r.ToCommand()
	if cmd.Name != "Bob" || cmd.Email != "bob@x.com" {
		t.Errorf("scalar fields not transferred: %+v", cmd)
	}
	if cmd.Phone == nil || *cmd.Phone != "11999999999" {
		t.Errorf("Phone not transferred: %v", cmd.Phone)
	}
	if len(cmd.Addresses) != 1 || cmd.Addresses[0].Street != "S1" {
		t.Errorf("Addresses not transferred: %+v", cmd.Addresses)
	}
}

func TestUpdateUserRequest_ToCommand_PhoneNil(t *testing.T) {
	r := UpdateUserRequest{Name: "x", Email: "y@z.w"} // Phone omitido
	cmd := r.ToCommand()
	if cmd.Phone != nil {
		t.Errorf("expected nil Phone, got %v", cmd.Phone)
	}
}

func TestUpdateUserRequest_ToCommand_EmptyAddressesAllowed(t *testing.T) {
	r := UpdateUserRequest{Name: "x", Email: "y@z.w", Addresses: []AddressRequest{}}
	cmd := r.ToCommand()
	if len(cmd.Addresses) != 0 {
		t.Errorf("expected 0 addresses, got %d", len(cmd.Addresses))
	}
}

// ─── Output: FromResult ──────────────────────────────────────────────────────

func TestUpdateUserResponse_FromResult(t *testing.T) {
	id := domain.NewRandomID()
	r := commands.UpdateUserResult{ID: id, Name: "Bob", Email: "b@x.com"}

	resp := UpdateUserResponse{}.FromResult(r)

	if resp.ID != id {
		t.Errorf("ID mismatch: got %v, want %v", resp.ID, id)
	}
	if resp.Name != "Bob" || resp.Email != "b@x.com" {
		t.Errorf("scalar fields not transferred: %+v", resp)
	}
}
