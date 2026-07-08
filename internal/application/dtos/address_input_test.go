package dtos

import (
	"testing"
)

func ptr(s string) *string { return &s }

func TestAddressInput_ToAddress_AllFieldsCopied(t *testing.T) {
	label := "Home"
	comp := "Apt 12"
	in := AddressInput{
		Label:        &label,
		Street:       "Main St",
		Number:       "100",
		Complement:   &comp,
		Neighborhood: "Downtown",
		City:         "Berlin",
		State:        "BE",
		ZipCode:      "10115",
		Country:      "DE",
	}
	got := in.ToAddress()
	if got.Label == nil || *got.Label != "Home" {
		t.Errorf("Label not propagated: %v", got.Label)
	}
	if got.Street != "Main St" || got.Number != "100" || got.Neighborhood != "Downtown" ||
		got.City != "Berlin" || got.State != "BE" || got.ZipCode != "10115" || got.Country != "DE" {
		t.Errorf("required-field mismatch: %+v", got)
	}
	if got.Complement == nil || *got.Complement != "Apt 12" {
		t.Errorf("Complement not propagated: %v", got.Complement)
	}
}

func TestAddressInput_ToAddress_NilOptionalsPreserved(t *testing.T) {
	in := AddressInput{
		Street:       "X",
		Number:       "1",
		Neighborhood: "Y",
		City:         "Z",
		State:        "ZZ",
		ZipCode:      "0",
		Country:      "BR",
	}
	got := in.ToAddress()
	if got.Label != nil {
		t.Errorf("Label should stay nil, got %v", got.Label)
	}
	if got.Complement != nil {
		t.Errorf("Complement should stay nil, got %v", got.Complement)
	}
}

func TestAddressInputCustom_ToAddress_AllFieldsCopied(t *testing.T) {
	label := "Office"
	comp := "Floor 3"
	in := AddressInputCustom{
		Label:        &label,
		Street:       "1 Way",
		Number:       "99",
		Complement:   &comp,
		Neighborhood: "Park",
		City:         "Lisbon",
		State:        "LI",
		ZipCode:      "1000-001",
		Country:      "PT",
	}
	got := in.ToAddress()
	if got.Label == nil || *got.Label != "Office" {
		t.Errorf("Label not propagated: %v", got.Label)
	}
	if got.Street != "1 Way" || got.Number != "99" || got.Neighborhood != "Park" ||
		got.City != "Lisbon" || got.State != "LI" || got.ZipCode != "1000-001" || got.Country != "PT" {
		t.Errorf("required-field mismatch: %+v", got)
	}
	if got.Complement == nil || *got.Complement != "Floor 3" {
		t.Errorf("Complement not propagated: %v", got.Complement)
	}
}

func TestAddressInputCustom_ToAddress_NilOptionalsPreserved(t *testing.T) {
	in := AddressInputCustom{Street: "S", Number: "1", Neighborhood: "N",
		City: "C", State: "ST", ZipCode: "0", Country: "BR"}
	got := in.ToAddress()
	if got.Label != nil || got.Complement != nil {
		t.Errorf("optionals should stay nil, got Label=%v Complement=%v",
			got.Label, got.Complement)
	}
}

// Sanity: AddressInput.ToAddress and AddressInputCustom.ToAddress emit the
// SAME domain shape when called with equivalent inputs. Locks the
// "manual showcase shares only domain/" invariant.
func TestAddressInput_AndCustomConverge(t *testing.T) {
	label := "L"
	a := AddressInput{Label: &label, Street: "S", Number: "1", Neighborhood: "N",
		City: "C", State: "ST", ZipCode: "0", Country: "BR"}.ToAddress()
	c := AddressInputCustom{Label: &label, Street: "S", Number: "1", Neighborhood: "N",
		City: "C", State: "ST", ZipCode: "0", Country: "BR"}.ToAddress()
	if a.Street != c.Street || a.Country != c.Country {
		t.Errorf("AddressInput vs Custom diverged: %+v vs %+v", a, c)
	}
}

// Compile-time check on the optional-field convention.
func TestAddressInput_OptionalsArePointers(t *testing.T) {
	var a AddressInput
	a.Label = ptr("x")
	a.Complement = ptr("y")
	if a.Label == nil || a.Complement == nil {
		t.Error("pointer assignment failed")
	}
}
