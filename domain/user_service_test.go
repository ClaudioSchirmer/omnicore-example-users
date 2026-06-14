package domain_test

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// fakeUserService lets us control the result of EmailExists and inspect that
// excludeID was passed correctly (nil on Insert; *u.GetID() on Update).
type fakeUserService struct {
	domain.ServiceBase
	exists                bool
	calls                 int
	lastEmail             string
	lastExcludeID         *domain.ID
	lastExcludeIDWasEmpty bool
}

func (s *fakeUserService) EmailExists(email string, excludeID *domain.ID) bool {
	s.calls++
	s.lastEmail = email
	s.lastExcludeID = excludeID
	if excludeID != nil {
		s.lastExcludeIDWasEmpty = excludeID.IsEmpty()
	}
	return s.exists
}

// Compile-time check.
var _ appdomain.UserService = (*fakeUserService)(nil)

// ─── Insert path ─────────────────────────────────────────────────────────────

func TestUser_BuildRules_Insert_CallsEmailExistsWithoutExcludeID(t *testing.T) {
	svc := &fakeUserService{exists: false}
	u := &appdomain.User{Name: "Jane", Email: "jane@example.com"}
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeInsert, svc)
	if !ok {
		t.Fatalf("expected validation to pass when email is unique; got %s", dumpContexts(ctxs))
	}
	if svc.calls != 1 {
		t.Fatalf("expected EmailExists called once; got %d", svc.calls)
	}
	if svc.lastEmail != "jane@example.com" {
		t.Errorf("expected email passed to service; got %q", svc.lastEmail)
	}
	// Insert: GetID() returns nil on a freshly constructed entity.
	if svc.lastExcludeID != nil {
		t.Errorf("expected excludeID nil on Insert (no ID yet); got %v (empty=%v)",
			svc.lastExcludeID, svc.lastExcludeIDWasEmpty)
	}
}

func TestUser_BuildRules_Insert_EmailExistsTriggersConflict(t *testing.T) {
	svc := &fakeUserService{exists: true}
	u := &appdomain.User{Name: "Jane", Email: "taken@example.com"}
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeInsert, svc)
	if ok {
		t.Fatal("expected validation to fail when EmailExists returns true")
	}
	if !hasNotification(ctxs, "email", "EmailAlreadyExistsNotification") {
		t.Fatalf("expected EmailAlreadyExistsNotification on email; got %s", dumpContexts(ctxs))
	}
}

// When the email is invalid by shape, EmailExists must not be called — the
// validation is chained: required → regex → unique. Avoids a DB ping for
// emails that would never reach COMMIT.
func TestUser_BuildRules_Insert_InvalidEmailShortCircuits(t *testing.T) {
	svc := &fakeUserService{exists: true}
	u := &appdomain.User{Name: "Jane", Email: "not-an-email"}
	u.AddAddress(validAddress(), nil)

	ok, _ := domain.IsValid(u, domain.ModeInsert, svc)
	if ok {
		t.Fatal("expected validation to fail on invalid email shape")
	}
	if svc.calls != 0 {
		t.Errorf("expected EmailExists NOT called when email shape is invalid; got %d calls", svc.calls)
	}
}

// ─── Update path ─────────────────────────────────────────────────────────────

func TestUser_BuildRules_Update_PassesOwnIDAsExclude(t *testing.T) {
	svc := &fakeUserService{exists: false}
	u := &appdomain.User{Name: "Jane", Email: "jane@example.com"}
	id := domain.NewRandomID()
	u.SetID(id)
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeUpdate, svc)
	if !ok {
		t.Fatalf("expected validation to pass; got %s", dumpContexts(ctxs))
	}
	if svc.calls != 1 {
		t.Fatalf("expected EmailExists called once; got %d", svc.calls)
	}
	if svc.lastExcludeID == nil {
		t.Fatal("expected excludeID to be set on Update")
	}
	if svc.lastExcludeID.Value() != id.Value() {
		t.Errorf("expected excludeID == own ID; got %q vs own %q",
			svc.lastExcludeID.Value(), id.Value())
	}
}

// When another user already owns the email (EmailExists true even with
// excludeID), the Update fails with Conflict — simulates the attempt to
// "switch to someone else's email".
func TestUser_BuildRules_Update_EmailExistsTriggersConflict(t *testing.T) {
	svc := &fakeUserService{exists: true}
	u := &appdomain.User{Name: "Jane", Email: "taken@example.com"}
	u.SetID(domain.NewRandomID())
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeUpdate, svc)
	if ok {
		t.Fatal("expected Update to fail when email is taken by another user")
	}
	if !hasNotification(ctxs, "email", "EmailAlreadyExistsNotification") {
		t.Fatalf("expected EmailAlreadyExistsNotification; got %s", dumpContexts(ctxs))
	}
}

// ─── Service nil contract ────────────────────────────────────────────────────

// User declares RequiresService() = true; calling GetInsertable without a
// service must emit ServiceIsRequiredNotification (framework rule, validated
// here as end-to-end integration proof from the example side).
func TestUser_RequiresService_ServiceNilFailsValidation(t *testing.T) {
	u := &appdomain.User{Name: "Jane", Email: "jane@example.com"}
	u.AddAddress(validAddress(), nil)

	if _, err := domain.GetInsertable(u, nil, "GetInsertable"); err == nil {
		t.Fatal("expected GetInsertable to fail when service is nil")
	} else {
		var carrier domain.NotificationCarrier
		if !asCarrier(err, &carrier) {
			t.Fatalf("error did not implement NotificationCarrier: %v", err)
		}
		if !hasNotification(carrier.NotificationContexts(), "service", "ServiceIsRequiredNotification") {
			t.Fatalf("expected ServiceIsRequiredNotification; got %s",
				dumpContexts(carrier.NotificationContexts()))
		}
	}
}
