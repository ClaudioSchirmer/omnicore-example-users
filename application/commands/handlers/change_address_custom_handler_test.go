package handlers

import (
	"testing"

	"github.com/google/uuid"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	"github.com/ClaudioSchirmer/omnicore-example-users/application/dtos"
)

func TestChangeAddressCustomCommandHandler_HappyPath(t *testing.T) {
	user := newPersistedUser(t)
	// Read the seeded child's ID from the aggregate so we target it
	// without coupling to the helper's UUID generation.
	var existingAddressID string
	for _, m := range user.AggregateRoot.AllAggregateItems() {
		for _, it := range m {
			existingAddressID = it.Item.GetID()
		}
	}
	if existingAddressID == "" {
		t.Fatalf("fixture did not seed an address")
	}

	repo := &fakeRepo{foundUser: user}
	h := &ChangeAddressCustomCommandHandler{Repo: repo, Service: fakeService{}}

	newLabel := "office"
	cmd := &commands.ChangeAddressCustomCommand{
		DocumentKey: "jane@example.com",
		AddressID:   existingAddressID,
		Address: dtos.AddressInputCustom{
			Label:        &newLabel,
			Street:       "2 New Way",
			Number:       "2",
			Neighborhood: "SoMa",
			City:         "San Francisco",
			State:        "CA",
			ZipCode:      "94110",
			Country:      "US",
		},
	}

	result, err := h.Handle(testCtx(), cmd)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Email != "jane@example.com" {
		t.Errorf("expected Email preserved, got %q", result.Email)
	}
	if len(result.Addresses) != 1 {
		t.Fatalf("expected one address in result, got %d", len(result.Addresses))
	}
	if result.Addresses[0].ID != existingAddressID {
		t.Errorf("expected address ID preserved, got %q", result.Addresses[0].ID)
	}
	if result.Addresses[0].Street != "2 New Way" {
		t.Errorf("expected new Street, got %q", result.Addresses[0].Street)
	}
	if repo.updateCalled != 1 {
		t.Errorf("expected Update called once, got %d", repo.updateCalled)
	}
}

func TestChangeAddressCustomCommandHandler_NotFound(t *testing.T) {
	repo := &fakeRepo{} // foundUser nil → FindByDocument returns errNotFound
	h := &ChangeAddressCustomCommandHandler{Repo: repo, Service: fakeService{}}

	cmd := &commands.ChangeAddressCustomCommand{
		DocumentKey: "ghost@example.com",
		AddressID:   uuid.NewString(),
	}

	_, err := h.Handle(testCtx(), cmd)
	if err == nil {
		t.Fatal("expected error from FindByDocument miss")
	}
	if repo.updateCalled != 0 {
		t.Errorf("expected Update NOT called, got %d", repo.updateCalled)
	}
}
