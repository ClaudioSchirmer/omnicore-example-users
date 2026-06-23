package handlers

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	"github.com/ClaudioSchirmer/omnicore-example-users/application/dtos"
)

// TestInsertUserCustomCommandHandler_HappyPath proves the manual Insert chain:
// ToEntity → GetInsertable → Orchestrator.Insert → SetID → FromEntity →
// produces a UserCustomResult with a populated ID and triggers exactly one
// Repo.Insert call. Validates the contract the showcase responses depend on
// (web/responses.FromResult reads result.ID directly).
func TestInsertUserCustomCommandHandler_HappyPath(t *testing.T) {
	repo := &fakeRepo{}
	h := &InsertUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	cmd := &commands.InsertUserCustomCommand{
		Name:  "Jane Doe",
		Email: "jane@example.com",
		Addresses: []dtos.AddressInputCustom{{
			Street:       "1 Infinite Loop",
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
	if result.ID.IsEmpty() {
		t.Error("expected result to have an ID populated by SetID before FromEntity")
	}
	if result.Name != "Jane Doe" || result.Email != "jane@example.com" {
		t.Errorf("unexpected result fields: %+v", result)
	}
	if len(result.Addresses) != 1 {
		t.Errorf("expected 1 address projected onto the result, got %d", len(result.Addresses))
	}
	if repo.insertCalled != 1 {
		t.Errorf("expected Insert called once, got %d", repo.insertCalled)
	}
}

// TestInsertUserCustomCommandHandler_PropagatesValidationError surfaces a BuildRules
// rejection: empty email triggers InvalidEmailNotification, GetInsertable
// returns a *DomainError, handler returns it unchanged so the wire layer
// converts to 422. The Repo must NOT be called when validation fails.
func TestInsertUserCustomCommandHandler_PropagatesValidationError(t *testing.T) {
	repo := &fakeRepo{}
	h := &InsertUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	cmd := &commands.InsertUserCustomCommand{Name: "X", Email: ""}

	_, err := h.Handle(testCtx(), cmd)
	if err == nil {
		t.Fatal("expected validation error for empty email")
	}
	if repo.insertCalled != 0 {
		t.Errorf("expected Insert NOT called on validation failure, got %d", repo.insertCalled)
	}
}
