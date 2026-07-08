package handlers

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
)

// TestUnarchiveUserCustomCommandHandler_HappyPath proves the restore lifecycle uses
// FindArchivedByDocument (not FindByDocument) because the canonical FindByDocument
// filters deleted_at IS NULL — an archived row would surface as NotFound.
// Repo.Unarchive runs once. Handler returns fwresults.None — same shape as
// the canonical Auto Unarchive handler.
func TestUnarchiveUserCustomCommandHandler_HappyPath(t *testing.T) {
	repo := &fakeRepo{foundArchivedUser: newPersistedUser(t)}
	h := &UnarchiveUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	cmd := &commands.UnarchiveUserCustomCommand{DocumentKey: "10000000001"}

	_, err := h.Handle(testCtx(), cmd)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if repo.unarchiveCalled != 1 {
		t.Errorf("expected Unarchive called once, got %d", repo.unarchiveCalled)
	}
}

// TestUnarchiveUserCustomCommandHandler_NotFound covers unarchive of an email that has
// no archived row — fakeRepo returns errNotFound from FindArchivedByDocument.
// Mirrors the wire 404 the canonical /users/:id/unarchive emits when the
// id has no archived row.
func TestUnarchiveUserCustomCommandHandler_NotFound(t *testing.T) {
	repo := &fakeRepo{} // foundArchivedUser nil
	h := &UnarchiveUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	cmd := &commands.UnarchiveUserCustomCommand{DocumentKey: "ghost@example.com"}

	_, err := h.Handle(testCtx(), cmd)
	if err == nil {
		t.Fatal("expected not-found error from FindArchivedByDocument miss")
	}
	if repo.unarchiveCalled != 0 {
		t.Errorf("expected Unarchive NOT called on miss, got %d", repo.unarchiveCalled)
	}
}
