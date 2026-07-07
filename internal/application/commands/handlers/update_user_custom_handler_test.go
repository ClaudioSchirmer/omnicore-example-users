package handlers

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
)

// TestUpdateUserCustomCommandHandler_HappyPath proves the FindByDocument →
// GetUpdatable → Orchestrator.Update lifecycle. ApplyTo replaces the editable
// fields (Name/Email/Phone/UserName/notifications + the full address
// collection); the document (the natural key) is not in the request, so the
// immutable-document guard stays silent.
func TestUpdateUserCustomCommandHandler_HappyPath(t *testing.T) {
	repo := &fakeRepo{foundUser: newPersistedUser(t)}
	h := &UpdateUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	newPhone := "14155553333"
	cmd := &commands.UpdateUserCustomCommand{
		DocumentKey: "10000000001",
		Name:        "Jane Smith",
		Email:       "jane.new@example.com",
		Phone:       &newPhone,
		UserName:    "jane",
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
	// Email is now a plain mutable shared field — the update changes it.
	if result.Email != "jane.new@example.com" {
		t.Errorf("expected Email updated, got %q", result.Email)
	}
	if repo.updateCalled != 1 {
		t.Errorf("expected Update called once, got %d", repo.updateCalled)
	}
}

// TestUpdateUserCustomCommandHandler_NotFound asserts the FindByDocument miss propagates to
// the caller — the wire layer surfaces it as 404 via RespondFromResult.
func TestUpdateUserCustomCommandHandler_NotFound(t *testing.T) {
	repo := &fakeRepo{} // foundUser nil → FindByDocument returns errNotFound
	h := &UpdateUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	cmd := &commands.UpdateUserCustomCommand{DocumentKey: "ghost@example.com", Name: "Ghost"}

	_, err := h.Handle(testCtx(), cmd)
	if err == nil {
		t.Fatal("expected not-found error from FindByDocument miss")
	}
	if repo.updateCalled != 0 {
		t.Errorf("expected Update NOT called on lookup miss, got %d", repo.updateCalled)
	}
}
