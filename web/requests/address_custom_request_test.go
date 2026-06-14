package requests

import (
	"testing"
)

func TestAddressCustomRequest_ToAddressInput_AllFields(t *testing.T) {
	r := AddressCustomRequest{
		Label:        strptr("home"),
		Street:       "Rua A",
		Number:       "123",
		Complement:   strptr("apto 7"),
		Neighborhood: "Centro",
		City:         "Recife",
		State:        "PE",
		ZipCode:      "50000-000",
		Country:      "BR",
	}
	got := r.ToAddressInput()
	if got.Label == nil || *got.Label != "home" {
		t.Errorf("Label not transferred: %v", got.Label)
	}
	if got.Street != "Rua A" {
		t.Errorf("Street mismatch: %q", got.Street)
	}
	if got.Number != "123" {
		t.Errorf("Number mismatch: %q", got.Number)
	}
	if got.Complement == nil || *got.Complement != "apto 7" {
		t.Errorf("Complement not transferred: %v", got.Complement)
	}
	if got.Country != "BR" {
		t.Errorf("Country mismatch: %q", got.Country)
	}
}

func TestAddressCustomRequest_ToAddressInput_NilOptionalsStayNil(t *testing.T) {
	r := AddressCustomRequest{
		Street:       "Rua B",
		Number:       "456",
		Neighborhood: "Bairro",
		City:         "City",
		State:        "ST",
		ZipCode:      "12345",
		Country:      "US",
	}
	got := r.ToAddressInput()
	if got.Label != nil {
		t.Errorf("expected Label=nil, got %v", got.Label)
	}
	if got.Complement != nil {
		t.Errorf("expected Complement=nil, got %v", got.Complement)
	}
}

func TestAddressCustomRequest_ToAddressInput_EmptyStringOptionalsPreserved(t *testing.T) {
	empty := ""
	r := AddressCustomRequest{
		Label:      &empty,
		Complement: &empty,
		Street:     "X",
		Number:     "1",
		City:       "Y",
		State:      "Z",
		ZipCode:    "12345",
		Country:    "US",
	}
	got := r.ToAddressInput()
	if got.Label == nil || *got.Label != "" {
		t.Errorf("expected Label=*'', got %v", got.Label)
	}
	if got.Complement == nil || *got.Complement != "" {
		t.Errorf("expected Complement=*'', got %v", got.Complement)
	}
}
