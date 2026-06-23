package handlers

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	"github.com/ClaudioSchirmer/omnicore-example-users/application/dtos"
)

// TestUpdateUserCustomCommandHandler_HappyPath proves the FindByEmail → GetUpdatable →
// Orchestrator.Update lifecycle. ApplyTo replaces Name + Phone + Addresses
// while leaving Email untouched (the showcase treats email as immutable),
// so the BuildRules immutable-email guard does not fire — exactly the
// design we picked for /:email-keyed routes.
func TestUpdateUserCustomCommandHandler_HappyPath(t *testing.T) {
	repo := &fakeRepo{foundUser: newPersistedUser(t)}
	h := &UpdateUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	newPhone := "14155553333"
	cmd := &commands.UpdateUserCustomCommand{
		EmailKey: "jane@example.com",
		Name:     "Jane Smith",
		Phone:    &newPhone,
		Addresses: []dtos.AddressInputCustom{{
			Street:       "1 Apple Park Way",
			Number:       "1",
			Neighborhood: "Mariani",
			City:         "Cupertino",
			State:        "CA",
			ZipCode:      "95014",
			Country:      "US",
		}},
	}

	result, err := h.Handle(testCtx(), cmd)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Name != "Jane Smith" {
		t.Errorf("expected Name updated, got %q", result.Name)
	}
	if result.Phone == nil || *result.Phone != newPhone {
		t.Errorf("expected Phone updated, got %v", result.Phone)
	}
	if result.Email != "jane@example.com" {
		t.Errorf("expected Email immutable, got %q", result.Email)
	}
	if repo.updateCalled != 1 {
		t.Errorf("expected Update called once, got %d", repo.updateCalled)
	}
}

// TestUpdateUserCustomCommandHandler_NotFound asserts the FindByEmail miss propagates to
// the caller — the wire layer surfaces it as 404 via RespondFromResult.
func TestUpdateUserCustomCommandHandler_NotFound(t *testing.T) {
	repo := &fakeRepo{} // foundUser nil → FindByEmail returns errNotFound
	h := &UpdateUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	cmd := &commands.UpdateUserCustomCommand{EmailKey: "ghost@example.com", Name: "Ghost"}

	_, err := h.Handle(testCtx(), cmd)
	if err == nil {
		t.Fatal("expected not-found error from FindByEmail miss")
	}
	if repo.updateCalled != 0 {
		t.Errorf("expected Update NOT called on lookup miss, got %d", repo.updateCalled)
	}
}
