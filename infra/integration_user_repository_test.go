//go:build integration

package infra

import (
	"errors"
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/domain"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// testCtx is the request-scoped AppContext the write binding (repo.Scope) needs;
// writes go through Scope(ctx) so cancellation + actor bind to the operation.
func testCtx() *configuration.AppContext {
	return configuration.NewAppContextWithRandomID(configuration.LangENG)
}

// --- helpers --------------------------------------------------------------

// stubUserService is the domain.Service shim used by GetInsertable/GetUpdatable
// to satisfy User's RequiresService=true gate. UserService.EmailExists always
// returns false in the test path — the real uniqueness enforcement comes from
// the database's unique index; the tests assert on that path explicitly.
type stubUserService struct{ domain.ServiceBase }

func (stubUserService) EmailExists(string, *domain.ID) bool { return false }

func newInsertableUser(t *testing.T, name, email string, addresses ...appdomain.Address) domain.Insertable {
	t.Helper()
	u := &appdomain.User{Name: name, Email: email}
	for _, a := range addresses {
		u.AddAddress(a, nil)
	}
	ins, err := domain.GetInsertable(u, stubUserService{}, "GetInsertable")
	if err != nil {
		t.Fatalf("GetInsertable %q: %v", email, err)
	}
	return ins
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
	ins := newInsertableUser(t, "Alice", "alice@x.com", sampleAddress())

	id, err := repo.Scope(testCtx()).Insert(ins)
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

	addrs := domain.GetCurrentItemsOf[appdomain.Address](&got.AggregateRoot)
	if len(addrs) != 1 || addrs[0].Street != "Main" {
		t.Errorf("expected 1 hydrated address, got %+v", addrs)
	}
}

func TestUserRepository_DuplicateEmailIsTypedConflict(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()

	repo := NewUserRepository(eng)
	if _, err := repo.Scope(testCtx()).Insert(newInsertableUser(t, "A", "same@x.com", sampleAddress())); err != nil {
		t.Fatalf("first Insert: %v", err)
	}

	_, err := repo.Scope(testCtx()).Insert(newInsertableUser(t, "B", "same@x.com", sampleAddress()))
	if err == nil {
		t.Fatal("expected duplicate email to error")
	}

	var carrier domain.NotificationCarrier
	if !errors.As(err, &carrier) {
		t.Fatalf("expected NotificationCarrier, got %T", err)
	}
	msgs := carrier.NotificationContexts()[0].Messages()
	if domain.NotificationKey(msgs[0].Notification) != "EmailAlreadyExistsNotification" {
		t.Errorf("expected EmailAlreadyExistsNotification, got %v", msgs[0].Notification)
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

	id, _ := repo.Scope(testCtx()).Insert(newInsertableUser(t, "X", "x@x.com", sampleAddress()))

	loaded, err := repo.FindByID(id)
	if err != nil {
		t.Fatalf("FindByID: %v", err)
	}

	arch, err := domain.GetArchivable(loaded, stubUserService{}, "GetArchivable")
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

	una, err := domain.GetUnarchivable(archived, stubUserService{}, "GetUnarchivable")
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

func TestUserRepository_NewReturnsFactoryResult(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()
	repo := NewUserRepository(eng)
	got := repo.New()
	if got == nil {
		t.Error("expected New() to return a non-nil entity")
	}
}

// --- UserService ----------------------------------------------------------

func TestUserService_EmailExists(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()
	repo := NewUserRepository(eng)
	svc := NewUserService(eng)

	id, _ := repo.Scope(testCtx()).Insert(newInsertableUser(t, "U", "u@x.com", sampleAddress()))

	if !svc.EmailExists("u@x.com", nil) {
		t.Error("EmailExists should be true for seeded email when excludeID is nil")
	}
	if svc.EmailExists("u@x.com", &id) {
		t.Error("EmailExists should be false when excludeID matches the row's id")
	}
	if svc.EmailExists("missing@x", nil) {
		t.Error("EmailExists should be false for absent email")
	}

	// Empty excludeID also takes the no-exclude branch.
	empty := domain.ID{}
	if !svc.EmailExists("u@x.com", &empty) {
		t.Error("EmailExists with empty excludeID should behave like nil")
	}
}

func TestUserService_EmailExists_IgnoresArchivedRows(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()
	repo := NewUserRepository(eng)
	svc := NewUserService(eng)

	id, _ := repo.Scope(testCtx()).Insert(newInsertableUser(t, "U", "u@x.com", sampleAddress()))

	loaded, _ := repo.FindByID(id)
	arch, _ := domain.GetArchivable(loaded, stubUserService{}, "GetArchivable")
	if err := repo.Scope(testCtx()).Archive(arch); err != nil {
		t.Fatalf("Archive: %v", err)
	}

	if svc.EmailExists("u@x.com", nil) {
		t.Error("EmailExists should be false for an archived email (soft-delete-aware uniqueness)")
	}
}

// --- UserCustomRepository -------------------------------------------------

func TestUserCustomRepository_FindByEmail_AndFindArchivedByEmail(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()

	canonical := NewUserRepository(eng)
	custom := NewUserCustomRepository(eng)

	id, err := canonical.Scope(testCtx()).Insert(newInsertableUser(t, "Alice", "alice@x.com", sampleAddress()))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	got, err := custom.FindByEmail("alice@x.com")
	if err != nil {
		t.Fatalf("FindByEmail: %v", err)
	}
	if got == nil || got.Email != "alice@x.com" {
		t.Errorf("FindByEmail returned %+v", got)
	}
	if got.GetID().Value() != id.Value() {
		t.Errorf("FindByEmail ID = %v, want %v", got.GetID(), id)
	}

	// Active row, FindArchivedByEmail should miss.
	if _, err := custom.FindArchivedByEmail("alice@x.com"); err == nil {
		t.Error("FindArchivedByEmail should miss while the row is active")
	}

	// Archive via canonical writes, then re-test.
	loaded, _ := canonical.FindByID(id)
	arch, _ := domain.GetArchivable(loaded, stubUserService{}, "GetArchivable")
	if err := canonical.Scope(testCtx()).Archive(arch); err != nil {
		t.Fatalf("Archive: %v", err)
	}

	archived, err := custom.FindArchivedByEmail("alice@x.com")
	if err != nil {
		t.Fatalf("FindArchivedByEmail after archive: %v", err)
	}
	if archived.Email != "alice@x.com" {
		t.Errorf("archived row = %+v", archived)
	}

	// FindByEmail (active-only) should now miss.
	if _, err := custom.FindByEmail("alice@x.com"); err == nil {
		t.Error("FindByEmail should miss after archive")
	}
}

func TestUserCustomRepository_FindByEmail_NotFoundError(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()
	custom := NewUserCustomRepository(eng)

	_, err := custom.FindByEmail("ghost@nowhere")
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

	// Insert via the custom Repository (1-line delegation to the engine Insert + outbox).
	ins := newInsertableUser(t, "C", "c@x.com", sampleAddress())
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
	upd, err := domain.GetUpdatable(loaded, func(u *appdomain.User) error { u.Name = "C2"; return nil }, stubUserService{}, "GetUpdatable")
	if err != nil {
		t.Fatalf("GetUpdatable: %v", err)
	}
	if err := custom.Scope(testCtx()).Update(upd); err != nil {
		t.Fatalf("custom Update: %v", err)
	}

	// Archive + Unarchive.
	reload, _ := custom.FindByID(id)
	arch, _ := domain.GetArchivable(reload, stubUserService{}, "GetArchivable")
	if err := custom.Scope(testCtx()).Archive(arch); err != nil {
		t.Fatalf("custom Archive: %v", err)
	}
	reArch, _ := custom.FindArchivedByID(id)
	una, _ := domain.GetUnarchivable(reArch, stubUserService{}, "GetUnarchivable")
	if err := custom.Scope(testCtx()).Unarchive(una); err != nil {
		t.Fatalf("custom Unarchive: %v", err)
	}

	// Delete.
	live, _ := custom.FindByID(id)
	del, _ := domain.GetDeletable(live, stubUserService{}, "GetDeletable")
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

func TestUserCustomRepository_DuplicateEmailMapsToTypedConflict(t *testing.T) {
	eng, cleanup := newTestEngine(t)
	defer cleanup()
	custom := NewUserCustomRepository(eng)

	if _, err := custom.Scope(testCtx()).Insert(newInsertableUser(t, "A", "dup@x.com", sampleAddress())); err != nil {
		t.Fatalf("first insert: %v", err)
	}
	_, err := custom.Scope(testCtx()).Insert(newInsertableUser(t, "B", "dup@x.com", sampleAddress()))
	if err == nil {
		t.Fatal("expected duplicate to fail")
	}
	var carrier domain.NotificationCarrier
	if !errors.As(err, &carrier) {
		t.Fatalf("expected NotificationCarrier, got %T", err)
	}
	if domain.NotificationKey(carrier.NotificationContexts()[0].Messages()[0].Notification) != "EmailAlreadyExistsNotification" {
		t.Errorf("expected EmailAlreadyExistsNotification")
	}
}
