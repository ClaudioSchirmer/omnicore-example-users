package requests

import (
	"testing"
)

func strptr(s string) *string { return &s }

func TestAddressRequest_ToAddressInput_AllFields(t *testing.T) {
	r := AddressRequest{
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

func TestAddressRequest_ToAddressInput_NilOptionalsStayNil(t *testing.T) {
	r := AddressRequest{
		Street:       "Rua B",
		Number:       "456",
		Neighborhood: "Bairro",
		City:         "City",
		State:        "ST",
		ZipCode:      "12345",
		Country:      "US",
		// Label e Complement omitidos → nil
	}
	got := r.ToAddressInput()
	if got.Label != nil {
		t.Errorf("expected Label=nil, got %v", got.Label)
	}
	if got.Complement != nil {
		t.Errorf("expected Complement=nil, got %v", got.Complement)
	}
}

func TestAddressRequest_ToAddressInput_EmptyStringOptionalsPreserved(t *testing.T) {
	// Phase 21: consumer sends "" explicitly — Request preserves *""
	// (without normalizing to nil). Domain decides whether to reject.
	empty := ""
	r := AddressRequest{
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
