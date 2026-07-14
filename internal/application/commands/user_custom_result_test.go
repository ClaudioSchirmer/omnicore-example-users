package commands

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/google/uuid"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// TestUserCustomResultFromUser_HappyPath proves the shared snapshot mapper
// packages root fields and the current aggregate children into a Go-pure
// DTO. AggregateConstructor seeds CONSTRUCTOR-status children that survive
// the GetCurrentItemsOf filter.
//
// userCustomResultFromUser is a package-private helper used by every
// body-emitting Cmd.FromEntity of the manual showcase (Insert/Update/Patch/
// ChangeAddress custom) — testing it directly covers all four call sites in
// one assertion sweep without depending on Cmd plumbing.
func TestUserCustomResultFromUser_HappyPath(t *testing.T) {
	phone := "14155552671"
	u := &appdomain.User{
		Name:  "Jane Doe",
		Email: "jane@example.com",
		Phone: &phone,
	}
	u.SetID(domain.NewID(uuid.NewString()))

	label := "home"
	u.AggregateConstructor([]domain.AggregateValueObject{
		appdomain.Address{
			ID:           domain.NewID(uuid.NewString()),
			Label:        &label,
			Street:       "1 Infinite Loop",
			Number:       "1",
			Neighborhood: "Mariani",
			City:         "Cupertino",
			State:        "CA",
			ZipCode:      "95014",
			Country:      "US",
		},
	})

	r := userCustomResultFromUser(u)

	if r.ID.IsEmpty() {
		t.Error("expected ID populated on the result")
	}
	if r.Name != "Jane Doe" || r.Email != "jane@example.com" {
		t.Errorf("root fields mismatch: %+v", r)
	}
	if r.Phone == nil || *r.Phone != phone {
		t.Errorf("expected Phone forwarded as pointer, got %v", r.Phone)
	}
	if len(r.Addresses) != 1 {
		t.Fatalf("expected 1 address on the result, got %d", len(r.Addresses))
	}
	a := r.Addresses[0]
	if a.Label == nil || *a.Label != "home" {
		t.Errorf("expected Label forwarded as pointer, got %v", a.Label)
	}
	if a.Street != "1 Infinite Loop" || a.ZipCode != "95014" || a.Country != "US" {
		t.Errorf("address fields mismatch: %+v", a)
	}
}

// TestUserCustomResultFromUser_NoAddresses covers the empty-aggregate path:
// a User without children still produces a valid Result with a non-nil empty
// slice (consumers can iterate without a nil check).
func TestUserCustomResultFromUser_NoAddresses(t *testing.T) {
	u := &appdomain.User{Name: "Solo", Email: "solo@example.com"}
	u.SetID(domain.NewID(uuid.NewString()))

	r := userCustomResultFromUser(u)

	if r.Addresses == nil {
		t.Error("expected non-nil empty slice, got nil")
	}
	if len(r.Addresses) != 0 {
		t.Errorf("expected 0 addresses, got %d", len(r.Addresses))
	}
}
