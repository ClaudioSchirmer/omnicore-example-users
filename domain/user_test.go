package domain_test

import (
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

func ptr(s string) *string { return &s }

// okService returns a UserService that always asserts "email does not exist"
// — used by tests that are not exercising the uniqueness rule and only need
// to satisfy User.RequiresService() = true.
func okService() *fakeUserService { return &fakeUserService{exists: false} }

// hasNotification returns true when at least one message across all contexts
// matches both the resolved field name and the Go type name of the notification.
func hasNotification(ctxs []*domain.NotificationContext, wantField, wantNotifType string) bool {
	for _, ctx := range ctxs {
		for _, msg := range ctx.Messages() {
			if msg.ResolveFieldName() == wantField &&
				reflect.TypeOf(msg.Notification).Name() == wantNotifType {
				return true
			}
		}
	}
	return false
}

// dumpContexts is a debug helper used in t.Fatalf to show what was actually
// emitted when an assertion fails.
func dumpContexts(ctxs []*domain.NotificationContext) string {
	var out []string
	for _, ctx := range ctxs {
		for _, msg := range ctx.Messages() {
			out = append(out, msg.ResolveFieldName()+":"+reflect.TypeOf(msg.Notification).Name())
		}
	}
	return "[" + strings.Join(out, ", ") + "]"
}

func validAddress() appdomain.Address {
	label := "home"
	return appdomain.Address{
		Label:        &label,
		Street:       "1 Infinite Loop",
		Number:       "1",
		Neighborhood: "Mariani",
		City:         "Cupertino",
		State:        "CA",
		ZipCode:      "95014",
		Country:      "US",
	}
}

// ─── User root validation ────────────────────────────────────────────────────

// ─── Layer-2 owner-check on Archive ──────────────────────────────────────────

// buildValidUser returns a User that passes Insert validation and carries an
// assigned ID — Archive/Unarchive/Delete reject entities without one
// (UnableToDeleteWithoutIDNotification), so the fixture mimics what
// FindByID would yield in production.
func buildValidUser(t *testing.T) *appdomain.User {
	t.Helper()
	u := &appdomain.User{
		Name:  "Jane Doe",
		Email: "jane@example.com",
		Phone: ptr("14155552671"),
	}
	u.SetID(domain.NewRandomID())
	u.AddAddress(validAddress(), nil)
	return u
}

func TestUser_BuildRules_Archive_NoPrincipal_Allows(t *testing.T) {
	// Auth disabled / no principal attached → degraded "trust" mode, no
	// owner-check fires. Mirrors the dev profile.
	u := buildValidUser(t)
	_, err := domain.GetArchivable(u, okService(), "GetArchivable")
	if err != nil {
		var carrier domain.NotificationCarrier
		if errors.As(err, &carrier) {
			t.Errorf("archive must succeed when no principal is attached, got: %s", dumpContexts(carrier.NotificationContexts()))
		} else {
			t.Errorf("archive must succeed when no principal is attached, got non-carrier err: %v", err)
		}
	}
}

func TestUser_BuildRules_Archive_OwnerEmailMatches_Allows(t *testing.T) {
	u := buildValidUser(t)
	u.RequestingPrincipalEmail = "jane@example.com" // same as u.Email
	_, err := domain.GetArchivable(u, okService(), "GetArchivable")
	if err != nil {
		t.Errorf("archive must succeed when principal email matches owner, got: %v", err)
	}
}

func TestUser_BuildRules_Archive_PrincipalIsAdmin_Allows(t *testing.T) {
	u := buildValidUser(t)
	u.RequestingPrincipalEmail = "admin@example.com" // different email
	u.RequestingPrincipalIsAdmin = true              // admin bypass
	_, err := domain.GetArchivable(u, okService(), "GetArchivable")
	if err != nil {
		t.Errorf("archive must succeed for admin even when emails differ, got: %v", err)
	}
}

func TestUser_BuildRules_Archive_NonOwnerNonAdmin_Rejects(t *testing.T) {
	u := buildValidUser(t)
	u.RequestingPrincipalEmail = "intruder@example.com"
	u.RequestingPrincipalIsAdmin = false
	_, err := domain.GetArchivable(u, okService(), "GetArchivable")
	if err == nil {
		t.Fatal("archive must reject when principal is neither owner nor admin")
	}
	var carrier domain.NotificationCarrier
	if !errors.As(err, &carrier) {
		t.Fatalf("error must be a NotificationCarrier; got %T: %v", err, err)
	}
	ctxs := carrier.NotificationContexts()
	if !hasNotification(ctxs, "id", "ArchiveNotAllowedNotification") {
		t.Fatalf("expected ArchiveNotAllowedNotification on field id; got %s", dumpContexts(ctxs))
	}
}

func TestUser_BuildRules_OwnerCheck_DoesNotFireOnUpdate(t *testing.T) {
	// PUT/PATCH branch (GetUpdatable / GetPartialUpdatable) must NOT trigger
	// the owner-check — only Archive does. Even with an intruder principal,
	// the Update path passes because the actionName branch in BuildRules
	// gates the owner-check.
	u := buildValidUser(t)
	u.RequestingPrincipalEmail = "intruder@example.com" // would fail Archive
	_, err := domain.GetUpdatable(u, func(*appdomain.User) {}, okService(), "GetUpdatable")
	if err != nil {
		var carrier domain.NotificationCarrier
		if errors.As(err, &carrier) {
			t.Errorf("Update must NOT trigger archive owner-check; got: %s", dumpContexts(carrier.NotificationContexts()))
		} else {
			t.Errorf("Update failed: %v", err)
		}
	}
}

func TestUser_BuildRules_HappyPath(t *testing.T) {
	u := &appdomain.User{
		Name:  "Jane Doe",
		Email: "jane@example.com",
		Phone: ptr("14155552671"),
	}
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeInsert, okService())
	if !ok {
		t.Fatalf("expected validation to pass, got: %s", dumpContexts(ctxs))
	}
}

func TestUser_BuildRules_NameRequired(t *testing.T) {
	u := &appdomain.User{Email: "jane@example.com"}
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeInsert, okService())
	if ok {
		t.Fatal("expected validation to fail")
	}
	if !hasNotification(ctxs, "name", "RequiredFieldNotification") {
		t.Fatalf("expected RequiredFieldNotification on name; got %s", dumpContexts(ctxs))
	}
}

func TestUser_BuildRules_EmailRequired(t *testing.T) {
	u := &appdomain.User{Name: "Jane"}
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeInsert, okService())
	if ok {
		t.Fatal("expected validation to fail")
	}
	if !hasNotification(ctxs, "email", "RequiredFieldNotification") {
		t.Fatalf("expected RequiredFieldNotification on email; got %s", dumpContexts(ctxs))
	}
}

func TestUser_BuildRules_EmailInvalid(t *testing.T) {
	cases := []struct {
		name  string
		email string
	}{
		{"no at sign", "not-an-email"},
		{"no tld", "jane@example"},
		{"empty local part", "@example.com"},
		{"trailing dot tld", "jane@example."},
		{"space inside", "ja ne@example.com"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			u := &appdomain.User{Name: "Jane", Email: c.email}
			u.AddAddress(validAddress(), nil)

			ok, ctxs := domain.IsValid(u, domain.ModeInsert, okService())
			if ok {
				t.Fatalf("expected validation to fail for %q", c.email)
			}
			if !hasNotification(ctxs, "email", "InvalidEmailNotification") {
				t.Fatalf("expected InvalidEmailNotification on email; got %s", dumpContexts(ctxs))
			}
		})
	}
}

func TestUser_BuildRules_PhoneOptional_NilPasses(t *testing.T) {
	u := &appdomain.User{Name: "Jane", Email: "jane@example.com", Phone: nil}
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeInsert, okService())
	if !ok {
		t.Fatalf("expected validation to pass; got %s", dumpContexts(ctxs))
	}
}

func TestUser_BuildRules_PhoneOptional_EmptyStringPasses(t *testing.T) {
	// Phase 21: web/requests/ does not normalize empty string to nil (Request
	// shape identical to Command, no NilIfEmpty at the boundary). BuildRules
	// short-circuits when *Phone == "" and tolerates the empty pointer
	// without rejecting.
	empty := ""
	u := &appdomain.User{Name: "Jane", Email: "jane@example.com", Phone: &empty}
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeInsert, okService())
	if !ok {
		t.Fatalf("expected validation to pass; got %s", dumpContexts(ctxs))
	}
}

func TestUser_BuildRules_PhoneInvalid(t *testing.T) {
	cases := []struct {
		name  string
		phone string
	}{
		{"too short", "12345"},
		{"too long", "1234567890123456"},
		{"non digit", "415-555-2671"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			u := &appdomain.User{Name: "Jane", Email: "jane@example.com", Phone: ptr(c.phone)}
			u.AddAddress(validAddress(), nil)

			ok, ctxs := domain.IsValid(u, domain.ModeInsert, okService())
			if ok {
				t.Fatalf("expected validation to fail for %q", c.phone)
			}
			if !hasNotification(ctxs, "phone", "InvalidPhoneNotification") {
				t.Fatalf("expected InvalidPhoneNotification on phone; got %s", dumpContexts(ctxs))
			}
		})
	}
}

// ─── AddAddress (Phase 20 invariants) ────────────────────────────────────────

func TestUser_AddAddress_AcceptsDistinct(t *testing.T) {
	u := &appdomain.User{Name: "Jane", Email: "jane@example.com"}
	a1 := validAddress()
	a2 := validAddress()
	a2.Number = "2"

	u.AddAddress(a1, nil)
	u.AddAddress(a2, nil)

	items := domain.GetCurrentItemsOf[appdomain.Address](&u.AggregateRoot)
	if len(items) != 2 {
		t.Fatalf("expected 2 addresses in the aggregate, got %d", len(items))
	}
}

func TestUser_AddAddress_RejectsDuplicateBusinessIdentity(t *testing.T) {
	u := &appdomain.User{Name: "Jane", Email: "jane@example.com"}
	a := validAddress()
	dup := validAddress()
	// Different label/complement but same Country+ZIP+Street+Number → same business identity.
	other := "other"
	dup.Label = &other

	u.AddAddress(a, nil)
	u.AddAddress(dup, nil)

	items := domain.GetCurrentItemsOf[appdomain.Address](&u.AggregateRoot)
	if len(items) != 1 {
		t.Fatalf("expected duplicate to be rejected, got %d items", len(items))
	}
	// Construction-time notification surfaces via GetInsertable (IsValid clears
	// the context; GetInsertable preserves construction notifs through
	// checkAllNotifications).
	if _, err := domain.GetInsertable(u, okService(), "GetInsertable"); err == nil {
		t.Fatal("expected GetInsertable to fail due to DuplicateAddressNotification")
	} else {
		var carrier domain.NotificationCarrier
		if !asCarrier(err, &carrier) {
			t.Fatalf("error did not implement NotificationCarrier: %v", err)
		}
		if !hasNotification(carrier.NotificationContexts(), "address", "DuplicateAddressNotification") {
			t.Fatalf("expected DuplicateAddressNotification on address; got %s",
				dumpContexts(carrier.NotificationContexts()))
		}
	}
}

// asCarrier is a thin wrapper around errors.As to avoid importing "errors" in
// every test file; centralizes the type assertion shape.
func asCarrier(err error, target *domain.NotificationCarrier) bool {
	if err == nil {
		return false
	}
	c, ok := err.(domain.NotificationCarrier)
	if !ok {
		return false
	}
	*target = c
	return true
}

// ─── Email immutability (transition-aware invariant via domain.Old) ──────────
//
// These tests exercise the canonical use case of domain.Old[T]: comparing the
// pre-mutation state of the entity (snapshotted by the framework's Get* path)
// against the post-mutation state inside BuildRules.

func TestUser_EmailImmutable_RejectsChangeOnUpdate(t *testing.T) {
	u := &appdomain.User{
		Name:  "Jane Doe",
		Email: "jane@example.com",
		Phone: ptr("14155552671"),
	}
	u.SetID(domain.NewRandomID())
	u.AddAddress(validAddress(), nil)

	apply := func(x *appdomain.User) { x.Email = "jane.new@example.com" }

	_, err := domain.GetUpdatable(u, apply, okService(), "GetUpdatable")
	if err == nil {
		t.Fatal("expected GetUpdatable to fail when email is changed (immutable rule)")
	}
	var carrier domain.NotificationCarrier
	if !asCarrier(err, &carrier) {
		t.Fatalf("expected NotificationCarrier error; got %v", err)
	}
	if !hasNotification(carrier.NotificationContexts(), "email", "EmailCannotChangeNotification") {
		t.Fatalf("expected EmailCannotChangeNotification on email; got %s",
			dumpContexts(carrier.NotificationContexts()))
	}
}

func TestUser_EmailImmutable_AcceptsSameEmailOnUpdate(t *testing.T) {
	u := &appdomain.User{
		Name:  "Jane Doe",
		Email: "jane@example.com",
		Phone: ptr("14155552671"),
	}
	u.SetID(domain.NewRandomID())
	u.AddAddress(validAddress(), nil)

	// Apply mutates other fields but keeps email — the rule should be silent.
	apply := func(x *appdomain.User) {
		x.Name = "Jane Renamed"
		x.Phone = ptr("14155553333")
	}

	if _, err := domain.GetUpdatable(u, apply, okService(), "GetUpdatable"); err != nil {
		t.Fatalf("expected GetUpdatable to pass when email did not change; got %v", err)
	}
}

func TestUser_EmailImmutable_NoOpOnInsert(t *testing.T) {
	// Insert has no previous state (domain.Old returns nil) — the rule must
	// short-circuit and let any valid email through.
	u := &appdomain.User{
		Name:  "Jane Doe",
		Email: "jane@example.com",
		Phone: ptr("14155552671"),
	}
	u.AddAddress(validAddress(), nil)

	if _, err := domain.GetInsertable(u, okService(), "GetInsertable"); err != nil {
		t.Fatalf("expected GetInsertable to pass on a fresh user; got %v", err)
	}
}

func TestUser_EmailImmutable_FiresOnPartialUpdateToo(t *testing.T) {
	// PATCH (PartialUpdate) shares the same Get* path as PUT — the rule fires
	// equally because the framework snapshots before either apply closure runs.
	u := &appdomain.User{
		Name:  "Jane Doe",
		Email: "jane@example.com",
		Phone: ptr("14155552671"),
	}
	u.SetID(domain.NewRandomID())
	u.AddAddress(validAddress(), nil)

	apply := func(x *appdomain.User) { x.Email = "different@example.com" }

	_, err := domain.GetPartialUpdatable(u, apply, okService(), "GetPartialUpdatable")
	if err == nil {
		t.Fatal("expected GetPartialUpdatable to fail when email is changed")
	}
	var carrier domain.NotificationCarrier
	if !asCarrier(err, &carrier) {
		t.Fatalf("expected NotificationCarrier error; got %v", err)
	}
	if !hasNotification(carrier.NotificationContexts(), "email", "EmailCannotChangeNotification") {
		t.Fatalf("expected EmailCannotChangeNotification on email; got %s",
			dumpContexts(carrier.NotificationContexts()))
	}
}
