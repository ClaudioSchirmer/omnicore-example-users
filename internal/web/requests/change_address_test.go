package requests

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
)

func TestChangeAddressRequest_ToCommand_HappyPath(t *testing.T) {
	label := "home"
	complement := "Apt 4B"
	req := ChangeAddressRequest{
		AddressID:    "abc-123",
		Label:        &label,
		Street:       "1 Infinite Loop",
		Number:       "1",
		Complement:   &complement,
		Neighborhood: "Mariani",
		City:         "Cupertino",
		State:        "CA",
		ZipCode:      "95014",
		Country:      "US",
	}

	cmd := req.ToCommand()

	if cmd.AddressID != "abc-123" {
		t.Errorf("AddressID mismatch: got %q", cmd.AddressID)
	}
	if cmd.Address.Street != "1 Infinite Loop" || cmd.Address.ZipCode != "95014" {
		t.Errorf("address scalars not transferred: %+v", cmd.Address)
	}
	if cmd.Address.Label == nil || *cmd.Address.Label != "home" {
		t.Errorf("Label not transferred: %v", cmd.Address.Label)
	}
	if cmd.Address.Complement == nil || *cmd.Address.Complement != "Apt 4B" {
		t.Errorf("Complement not transferred: %v", cmd.Address.Complement)
	}
}

func TestChangeAddressRequest_ToCommand_NilOptionalsArrivePure(t *testing.T) {
	req := ChangeAddressRequest{
		AddressID:    "id",
		Street:       "Main",
		Number:       "1",
		Neighborhood: "X",
		City:         "Y",
		State:        "CA",
		ZipCode:      "94103",
		Country:      "US",
	}
	cmd := req.ToCommand()
	if cmd.Address.Label != nil {
		t.Errorf("expected nil Label, got %v", cmd.Address.Label)
	}
	if cmd.Address.Complement != nil {
		t.Errorf("expected nil Complement, got %v", cmd.Address.Complement)
	}
}

func TestChangeAddressResponse_FromResult(t *testing.T) {
	userID := domain.NewRandomID()
	label := "office"
	r := commands.ChangeAddressResult{
		UserID: userID,
		Address: commands.AddressResult{
			ID:           "addr-1",
			Label:        &label,
			Street:       "2 Update Lane",
			Number:       "2",
			Neighborhood: "SoMa",
			City:         "San Francisco",
			State:        "CA",
			ZipCode:      "94110",
			Country:      "US",
		},
	}

	got := ChangeAddressResponse{}.FromResult(r)

	if got.UserID != userID {
		t.Errorf("UserID mismatch: got %v, want %v", got.UserID, userID)
	}
	if got.Address.ID != "addr-1" || got.Address.ZipCode != "94110" {
		t.Errorf("scalar fields not transferred: %+v", got.Address)
	}
	if got.Address.Label == nil || *got.Address.Label != "office" {
		t.Errorf("Label not transferred: %v", got.Address.Label)
	}
}
