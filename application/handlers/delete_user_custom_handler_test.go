package handlers

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
)

// TestDeleteUserCustomCommandHandler_HappyPath proves the hard-delete lifecycle:
// FindByEmail → GetDeletable → Orchestrator.Delete. Returns struct{} so the
// wire layer can honor 204 No Content.
func TestDeleteUserCustomCommandHandler_HappyPath(t *testing.T) {
	repo := &fakeRepo{foundUser: newPersistedUser(t)}
	h := &DeleteUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	cmd := &commands.DeleteUserCustomCommand{EmailKey: "jane@example.com"}

	_, err := h.Handle(testCtx(), cmd)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if repo.deleteCalled != 1 {
		t.Errorf("expected Delete called once, got %d", repo.deleteCalled)
	}
}

// TestDeleteUserCustomCommandHandler_NotFound covers the FindByEmail miss — wire emits
// 404 via RecordNotFoundNotification.
func TestDeleteUserCustomCommandHandler_NotFound(t *testing.T) {
	repo := &fakeRepo{}
	h := &DeleteUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	cmd := &commands.DeleteUserCustomCommand{EmailKey: "ghost@example.com"}

	_, err := h.Handle(testCtx(), cmd)
	if err == nil {
		t.Fatal("expected not-found error from FindByEmail miss")
	}
	if repo.deleteCalled != 0 {
		t.Errorf("expected Delete NOT called on miss, got %d", repo.deleteCalled)
	}
}
