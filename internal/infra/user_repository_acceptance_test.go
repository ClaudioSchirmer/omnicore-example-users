//go:build integration

package infra

import (
	"errors"
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/domain"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// testCtx is the request-scoped AppContext the write binding (repo.Scope) needs;
// writes go through Scope(ctx) so cancellation + actor bind to the operation.
func testCtx() *configuration.AppContext {
	return configuration.NewAppContextWithRandomID(configuration.LangENG)
}

// --- helpers --------------------------------------------------------------
//
// The User is SharedBase-backed, so an insert is a load-first UPSERT: load the
// existing Person identity by the natural key (document), apply the request,
// then GetInsertable with "GetInsertable" (cold) or "GetUpsertable" (warm) and
// Insert. sharedBaseInserter mimics the SharedBaseInsertCommandHandler the wire
// path uses, so these integration tests exercise the same persister path. User
// needs no domain service, so a nil service is passed throughout.

// insertUser cold/warm-inserts a user for `document` through the SharedBase
// upsert path on the canonical repository.
func insertUser(t *testing.T, repo *UserRepository, document, name, email, userName string, addresses ...appdomain.Address) (domain.ID, error) {
	t.Helper()
	fresh := &appdomain.User{Document: document}
	loaded, existed, err := repo.LoadForSharedBaseInsert(testCtx(), fresh)
	if err != nil {
		// RETURN (don't t.Fatalf): since 775a3c6 the shared-base insert probe
		// pre-flights the "active role already exists" 409, so a typed conflict now
		// surfaces HERE rather than from Insert below. The caller decides whether an
		// error is expected — mirror the Insert path and hand it back.
		return domain.ID{}, err
	}
	loaded.Name = name
	loaded.Email = email
	loaded.Document = document
	loaded.UserName = userName
	for _, a := range addresses {
		loaded.AddAddress(a, nil)
	}
	action := "GetInsertable"
	if existed {
		action = "GetUpsertable"
	}
	ins, err := domain.GetInsertable(loaded, nil, action)
	if err != nil {
		return domain.ID{}, err
	}
	return repo.Scope(testCtx()).Insert(ins)
}

func sampleAddress() appdomain.Address {
	return appdomain.Address{
		Street: "Main", Number: "1", Neighborhood: "N",
		City: "Berlin", State: "BE", ZipCode: "10115", Country: "DE",
	}
}

// --- UserRepository (canonical) ------------------------------------------

func TestUserRepository_InsertAndFindByID(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()

	repo := NewUserRepository(eng)
	id, err := insertUser(t, repo, "10000000001", "Alice", "alice@x.com", "alice", sampleAddress())
	if err != nil {
		t.Fatalf("Insert: %v", err)
	}
	if id.IsEmpty() {
		t.Fatal("expected populated ID")
	}

	got, err := repo.FindByID(id)
	if err != nil {
		t.Fatalf("FindByID: %v", err)
	}
	if got.Name != "Alice" || got.Email != "alice@x.com" {
		t.Errorf("FindByID root = %+v", got)
	}
	// Shared Person fields + role-private field round-trip flat.
	if got.Document != "10000000001" || got.UserName != "alice" {
		t.Errorf("FindByID document/userName = %q/%q", got.Document, got.UserName)
	}

	// Addresses are the person's base-children, hydrated onto the role.
	addrs := domain.GetCurrentItemsOf[appdomain.Address](&got.AggregateRoot)
	if len(addrs) != 1 || addrs[0].Street != "Main" {
		t.Errorf("expected 1 hydrated address, got %+v", addrs)
	}
}

// A second POST for a document whose person already has an ACTIVE user is a 409
// EntityAlreadyAddedNotification (the SharedBase write matrix).
func TestUserRepository_DuplicateActiveUserIsTypedConflict(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()

	repo := NewUserRepository(eng)
	if _, err := insertUser(t, repo, "10000000002", "A", "a@x.com", "a", sampleAddress()); err != nil {
		t.Fatalf("first Insert: %v", err)
	}

	_, err := insertUser(t, repo, "10000000002", "B", "b@x.com", "b", sampleAddress())
	if err == nil {
		t.Fatal("expected duplicate active user to error")
	}
	var carrier domain.NotificationCarrier
	if !errors.As(err, &carrier) {
		t.Fatalf("expected NotificationCarrier, got %T", err)
	}
	msgs := carrier.NotificationContexts()[0].Messages()
	if domain.NotificationKey(msgs[0].Notification) != "EntityAlreadyAddedNotification" {
		t.Errorf("expected EntityAlreadyAddedNotification, got %v", msgs[0].Notification)
	}
}

func TestUserRepository_FindByID_NotFound(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()
	repo := NewUserRepository(eng)

	_, err := repo.FindByID(domain.NewID("00000000-0000-0000-0000-000000000000"))
	if err == nil {
		t.Fatal("expected NotFound when ID does not exist")
	}
}

func TestUserRepository_ArchiveAndUnarchiveCascade(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()
	repo := NewUserRepository(eng)

	id, _ := insertUser(t, repo, "10000000003", "X", "x@x.com", "x", sampleAddress())

	loaded, err := repo.FindByID(id)
	if err != nil {
		t.Fatalf("FindByID: %v", err)
	}

	arch, err := domain.GetArchivable(loaded, nil, "GetArchivable")
	if err != nil {
		t.Fatalf("GetArchivable: %v", err)
	}
	if err := repo.Scope(testCtx()).Archive(arch); err != nil {
		t.Fatalf("Archive: %v", err)
	}

	// FindByID (active-only) now misses.
	if _, err := repo.FindByID(id); err == nil {
		t.Error("FindByID should miss after archive")
	}
	// FindArchivedByID hydrates the archived snapshot.
	archived, err := repo.FindArchivedByID(id)
	if err != nil {
		t.Fatalf("FindArchivedByID: %v", err)
	}
	if archived.Name != "X" {
		t.Errorf("archived root = %+v", archived)
	}

	una, err := domain.GetUnarchivable(archived, nil, "GetUnarchivable")
	if err != nil {
		t.Fatalf("GetUnarchivable: %v", err)
	}
	if err := repo.Scope(testCtx()).Unarchive(una); err != nil {
		t.Fatalf("Unarchive: %v", err)
	}
	if _, err := repo.FindByID(id); err != nil {
		t.Errorf("FindByID should resolve after unarchive: %v", err)
	}
}

// Re-POSTing an ARCHIVED user's document does NOT revive it: the SharedBase
// insert probe is active-only, so the archived role is invisible and the
// shared-PK constraint arbitrates the remnant → a 409 typed conflict. Revival is
// EXCLUSIVELY via /unarchive (framework 775a3c6). After the unarchive the user is
// active again carrying its ORIGINAL fields — the rejected re-POST never applied.
func TestUserRepository_RePostArchivedDocumentConflictsUnarchiveRevives(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()
	repo := NewUserRepository(eng)

	id, _ := insertUser(t, repo, "10000000004", "R", "r@x.com", "r", sampleAddress())
	loaded, _ := repo.FindByID(id)
	arch, _ := domain.GetArchivable(loaded, nil, "GetArchivable")
	if err := repo.Scope(testCtx()).Archive(arch); err != nil {
		t.Fatalf("Archive: %v", err)
	}

	// Re-POST the same document while archived → a typed 409 conflict, NOT revival:
	// the archived role is invisible to the active-only insert probe, so the write
	// proceeds and the person's remnant constraints arbitrate it. Here the shared
	// base-child address (person-owned, NOT archived with the role) collides first
	// → DuplicateAddressNotification. Either way the re-POST is rejected.
	_, err := insertUser(t, repo, "10000000004", "R2", "r2@x.com", "r2", sampleAddress())
	if err == nil {
		t.Fatal("expected re-POST of an archived document to conflict, not revive")
	}
	var carrier domain.NotificationCarrier
	if !errors.As(err, &carrier) {
		t.Fatalf("expected NotificationCarrier, got %T", err)
	}
	if key := domain.NotificationKey(carrier.NotificationContexts()[0].Messages()[0].Notification); key != "DuplicateAddressNotification" {
		t.Errorf("expected a typed remnant conflict (DuplicateAddressNotification), got %v", key)
	}

	// /unarchive is the ONLY revival path.
	archived, err := repo.FindArchivedByID(id)
	if err != nil {
		t.Fatalf("FindArchivedByID: %v", err)
	}
	una, err := domain.GetUnarchivable(archived, nil, "GetUnarchivable")
	if err != nil {
		t.Fatalf("GetUnarchivable: %v", err)
	}
	if err := repo.Scope(testCtx()).Unarchive(una); err != nil {
		t.Fatalf("Unarchive: %v", err)
	}

	// Active again — with its ORIGINAL fields; the rejected re-POST never applied.
	got, err := repo.FindByID(id)
	if err != nil {
		t.Fatalf("FindByID after unarchive: %v", err)
	}
	if got.Email != "r@x.com" {
		t.Errorf("expected the unarchived user to keep its original fields, got %+v", got)
	}
}

func TestUserRepository_NewReturnsFactoryResult(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()
	repo := NewUserRepository(eng)
	got := repo.New()
	if got == nil {
		t.Error("expected New() to return a non-nil entity")
	}
}

// --- UserCustomRepository -------------------------------------------------

func TestUserCustomRepository_FindByDocument_AndFindArchivedByDocument(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()

	canonical := NewUserRepository(eng)
	custom := NewUserCustomRepository(eng)

	id, err := insertUser(t, canonical, "10000000005", "Alice", "alice@x.com", "alice", sampleAddress())
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	got, err := custom.FindByDocument("10000000005")
	if err != nil {
		t.Fatalf("FindByDocument: %v", err)
	}
	if got == nil || got.Document != "10000000005" {
		t.Errorf("FindByDocument returned %+v", got)
	}
	if got.GetID().Value() != id.Value() {
		t.Errorf("FindByDocument ID = %v, want %v", got.GetID(), id)
	}

	// Active row, FindArchivedByDocument should miss.
	if _, err := custom.FindArchivedByDocument("10000000005"); err == nil {
		t.Error("FindArchivedByDocument should miss while the row is active")
	}

	// Archive via canonical writes, then re-test.
	loaded, _ := canonical.FindByID(id)
	arch, _ := domain.GetArchivable(loaded, nil, "GetArchivable")
	if err := canonical.Scope(testCtx()).Archive(arch); err != nil {
		t.Fatalf("Archive: %v", err)
	}

	archived, err := custom.FindArchivedByDocument("10000000005")
	if err != nil {
		t.Fatalf("FindArchivedByDocument after archive: %v", err)
	}
	if archived.Document != "10000000005" {
		t.Errorf("archived row = %+v", archived)
	}

	// FindByDocument (active-only) should now miss.
	if _, err := custom.FindByDocument("10000000005"); err == nil {
		t.Error("FindByDocument should miss after archive")
	}
}

func TestUserCustomRepository_FindByDocument_NotFoundError(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()
	custom := NewUserCustomRepository(eng)

	_, err := custom.FindByDocument("99999999999")
	if err == nil {
		t.Fatal("expected NotFoundError")
	}
	var carrier domain.NotificationCarrier
	if !errors.As(err, &carrier) {
		t.Fatalf("expected NotificationCarrier, got %T", err)
	}
	msgs := carrier.NotificationContexts()[0].Messages()
	if domain.NotificationKey(msgs[0].Notification) != "RecordNotFoundNotification" {
		t.Errorf("expected RecordNotFoundNotification, got %v", msgs[0].Notification)
	}
}

func TestUserCustomRepository_WriteDelegations(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()
	custom := NewUserCustomRepository(eng)

	// Insert via the custom Repository's SharedBase upsert path.
	fresh := &appdomain.User{Document: "10000000006"}
	loaded0, existed, err := custom.LoadForSharedBaseInsert(testCtx(), fresh)
	if err != nil {
		t.Fatalf("LoadForSharedBaseInsert: %v", err)
	}
	loaded0.Name, loaded0.Email, loaded0.Document, loaded0.UserName = "C", "c@x.com", "10000000006", "c"
	loaded0.AddAddress(sampleAddress(), nil)
	action := "GetInsertable"
	if existed {
		action = "GetUpsertable"
	}
	ins, _ := domain.GetInsertable(loaded0, nil, action)
	id, err := custom.Scope(testCtx()).Insert(ins)
	if err != nil {
		t.Fatalf("custom Insert: %v", err)
	}
	if id.IsEmpty() {
		t.Fatal("expected populated id")
	}

	// FindByID via the framework loader through the custom Repository.
	loaded, err := custom.FindByID(id)
	if err != nil {
		t.Fatalf("custom FindByID: %v", err)
	}

	// Update.
	upd, err := domain.GetUpdatable(loaded, func(u *appdomain.User) error { u.Name = "C2"; return nil }, nil, "GetUpdatable")
	if err != nil {
		t.Fatalf("GetUpdatable: %v", err)
	}
	if err := custom.Scope(testCtx()).Update(upd); err != nil {
		t.Fatalf("custom Update: %v", err)
	}

	// Archive + Unarchive.
	reload, _ := custom.FindByID(id)
	arch, _ := domain.GetArchivable(reload, nil, "GetArchivable")
	if err := custom.Scope(testCtx()).Archive(arch); err != nil {
		t.Fatalf("custom Archive: %v", err)
	}
	reArch, _ := custom.FindArchivedByID(id)
	una, _ := domain.GetUnarchivable(reArch, nil, "GetUnarchivable")
	if err := custom.Scope(testCtx()).Unarchive(una); err != nil {
		t.Fatalf("custom Unarchive: %v", err)
	}

	// Delete (hard) — refcount drops the orphan person + its addresses too.
	live, _ := custom.FindByID(id)
	del, _ := domain.GetDeletable(live, nil, "GetDeletable")
	if err := custom.Scope(testCtx()).Delete(del); err != nil {
		t.Fatalf("custom Delete: %v", err)
	}
	if _, err := custom.FindByID(id); err == nil {
		t.Error("FindByID should miss after Delete")
	}
}

func TestUserCustomRepository_New(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()
	custom := NewUserCustomRepository(eng)
	if got := custom.New(); got == nil {
		t.Error("custom.New() should not return nil")
	}
}
