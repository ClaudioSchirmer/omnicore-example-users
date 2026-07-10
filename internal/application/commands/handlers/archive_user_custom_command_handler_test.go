package handlers

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
)

// TestArchiveUserCustomCommandHandler_HappyPath proves the soft-delete lifecycle:
// FindByDocument → GetArchivable → Orchestrator.Archive. Repo.Archive runs
// exactly once. The handler returns fwresults.None — same shape as the
// canonical Auto handler — so the wire layer emits the success envelope
// without a `data` field.
func TestArchiveUserCustomCommandHandler_HappyPath(t *testing.T) {
	repo := &fakeRepo{foundUser: newPersistedUser(t)}
	h := &ArchiveUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	cmd := &commands.ArchiveUserCustomCommand{DocumentKey: "10000000001"}

	_, err := h.Handle(testCtx(), cmd)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if repo.archiveCalled != 1 {
		t.Errorf("expected Archive called once, got %d", repo.archiveCalled)
	}
}

// TestArchiveUserCustomCommandHandler_NotFound covers the FindByDocument miss — archive of
// a non-existent email surfaces as RecordNotFoundNotification.
func TestArchiveUserCustomCommandHandler_NotFound(t *testing.T) {
	repo := &fakeRepo{}
	h := &ArchiveUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	cmd := &commands.ArchiveUserCustomCommand{DocumentKey: "ghost@example.com"}

	_, err := h.Handle(testCtx(), cmd)
	if err == nil {
		t.Fatal("expected not-found error from FindByDocument miss")
	}
	if repo.archiveCalled != 0 {
		t.Errorf("expected Archive NOT called on lookup miss, got %d", repo.archiveCalled)
	}
}
