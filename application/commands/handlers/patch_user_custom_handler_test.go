package handlers

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
)

// TestPatchUserCustomCommandHandler_PartialUpdate proves ApplyPartiallyTo applies only
// non-nil fields. Patching Name leaves Phone/Email untouched, and the
// repo's Update is called exactly once.
func TestPatchUserCustomCommandHandler_PartialUpdate(t *testing.T) {
	repo := &fakeRepo{foundUser: newPersistedUser(t)}
	h := &PatchUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	newName := "Jane Patched"
	cmd := &commands.PatchUserCustomCommand{
		DocumentKey: "10000000001",
		Name:        &newName,
	}

	result, err := h.Handle(testCtx(), cmd)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Name != newName {
		t.Errorf("expected Name patched to %q, got %q", newName, result.Name)
	}
	if result.Email != "jane@example.com" {
		t.Errorf("expected Email immutable, got %q", result.Email)
	}
	if result.Phone == nil || *result.Phone != "14155552671" {
		t.Errorf("expected Phone preserved, got %v", result.Phone)
	}
	if repo.updateCalled != 1 {
		t.Errorf("expected Update called once, got %d", repo.updateCalled)
	}
}

// TestPatchUserCustomCommandHandler_EmptyBody is the noop case — a PATCH with no fields
// still goes through the full lifecycle (BuildRules, Orchestrator.Update)
// and writes a row in the outbox via the canonical path. Repo.Update is
// called even when nothing changed; the canonical PartialUpdate behaves
// the same way.
func TestPatchUserCustomCommandHandler_EmptyBody(t *testing.T) {
	repo := &fakeRepo{foundUser: newPersistedUser(t)}
	h := &PatchUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	cmd := &commands.PatchUserCustomCommand{DocumentKey: "10000000001"}

	result, err := h.Handle(testCtx(), cmd)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Name != "Jane Doe" {
		t.Errorf("expected Name preserved on empty PATCH, got %q", result.Name)
	}
	if repo.updateCalled != 1 {
		t.Errorf("expected Update called once even on noop PATCH, got %d", repo.updateCalled)
	}
}
