package responses

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/google/uuid"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
)

// TestFromResult_HappyPath proves the wire mapper round-trips every field of
// the application Result onto its wire-format counterpart. Covers the
// rendering direction the manual showcase handlers depend on — a regression
// here surfaces as broken JSON shape on every /showcase/users-custom/*
// success response.
func TestFromResult_HappyPath(t *testing.T) {
	phone := "14155552671"
	label := "home"
	complement := "Apt 4B"
	in := commands.UserCustomResult{
		ID:    domain.NewID(uuid.NewString()),
		Name:  "Jane Doe",
		Email: "jane@example.com",
		Phone: &phone,
		Addresses: []commands.AddressCustomResult{{
			ID:           uuid.NewString(),
			Label:        &label,
			Street:       "1 Infinite Loop",
			Number:       "1",
			Complement:   &complement,
			Neighborhood: "Mariani",
			City:         "Cupertino",
			State:        "CA",
			ZipCode:      "95014",
			Country:      "US",
		}},
	}

	got := FromResult(in)

	if got.ID.Value() != in.ID.Value() {
		t.Errorf("ID mismatch: got %s, want %s", got.ID.Value(), in.ID.Value())
	}
	if got.Name != in.Name {
		t.Errorf("Name mismatch: got %q", got.Name)
	}
	if got.Email != in.Email {
		t.Errorf("Email mismatch: got %q", got.Email)
	}
	if got.Phone == nil || *got.Phone != phone {
		t.Errorf("Phone mismatch: got %v", got.Phone)
	}
	if len(got.Addresses) != 1 {
		t.Fatalf("expected 1 address, got %d", len(got.Addresses))
	}
	a := got.Addresses[0]
	srcA := in.Addresses[0]
	if a.ID != srcA.ID || a.Street != srcA.Street || a.City != srcA.City ||
		a.State != srcA.State || a.ZipCode != srcA.ZipCode || a.Country != srcA.Country {
		t.Errorf("address fields not round-tripped: got %+v", a)
	}
	if a.Label == nil || *a.Label != label {
		t.Errorf("address Label not round-tripped: got %v", a.Label)
	}
	if a.Complement == nil || *a.Complement != complement {
		t.Errorf("address Complement not round-tripped: got %v", a.Complement)
	}
}

// TestFromResult_NilPhone confirms a nullable root field renders as nil — the
// omitempty tag in UserCustomResponse then prunes the key on the wire. Mirrors
// the canonical /users/:id read-side behavior where phone NULL becomes an
// absent JSON key.
func TestFromResult_NilPhone(t *testing.T) {
	in := commands.UserCustomResult{
		ID:    domain.NewID(uuid.NewString()),
		Name:  "Bob",
		Email: "bob@example.com",
		Phone: nil,
	}

	got := FromResult(in)
	if got.Phone != nil {
		t.Errorf("expected nil Phone in response, got %v", got.Phone)
	}
}

// TestFromResult_EmptyAddresses proves a Result without children renders as an
// empty addresses slice (not nil) so the wire format always carries the
// `addresses` key.
func TestFromResult_EmptyAddresses(t *testing.T) {
	in := commands.UserCustomResult{
		ID:    domain.NewID(uuid.NewString()),
		Name:  "X",
		Email: "x@example.com",
	}

	got := FromResult(in)
	if got.Addresses == nil {
		t.Error("expected non-nil Addresses slice, got nil")
	}
	if len(got.Addresses) != 0 {
		t.Errorf("expected 0 addresses, got %d", len(got.Addresses))
	}
}
