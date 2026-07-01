package requests

import "testing"

func TestChangeAddressCustomRequest_ToCommand_HappyPath(t *testing.T) {
	label := "office"
	complement := "Suite 9"
	r := ChangeAddressCustomRequest{
		Document:     "10000000001",
		AddressID:    "addr-1",
		Label:        &label,
		Street:       "2 New Way",
		Number:       "2",
		Complement:   &complement,
		Neighborhood: "SoMa",
		City:         "San Francisco",
		State:        "CA",
		ZipCode:      "94110",
		Country:      "US",
	}

	cmd := r.ToCommand()

	if cmd.DocumentKey != "10000000001" {
		t.Errorf("DocumentKey mismatch: got %q", cmd.DocumentKey)
	}
	if cmd.AddressID != "addr-1" {
		t.Errorf("AddressID mismatch: got %q", cmd.AddressID)
	}
	if cmd.Address.Street != "2 New Way" || cmd.Address.ZipCode != "94110" {
		t.Errorf("address scalars not transferred: %+v", cmd.Address)
	}
	if cmd.Address.Label == nil || *cmd.Address.Label != "office" {
		t.Errorf("Label not transferred: %v", cmd.Address.Label)
	}
}
