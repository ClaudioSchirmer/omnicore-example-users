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
func bptr(b bool) *bool    { return &b }

// User needs no domain service now — identity uniqueness is enforced by the
// SharedBase write path, not by a domain lookup. So every Get*/IsValid call
// passes a nil service (RequiresService() is false, so the framework tolerates
// it). The shared helpers below build a User that satisfies the now-required
// Document (natural key) + UserName fields.

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

// validUser returns a flat User that passes Insert validation: the shared
// Person fields (Name/Email/Phone/Document) plus the role-private UserName, with
// one address. No ID — Insert fixtures want a fresh entity.
func validUser() *appdomain.User {
	return &appdomain.User{
		Name:     "Jane Doe",
		Email:    "jane@example.com",
		Phone:    ptr("14155552671"),
		Document: "10000000001",
		UserName: "jane",
	}
}

// ─── Layer-2 owner-check on Archive ──────────────────────────────────────────

// buildValidUser returns a User that passes Insert validation and carries an
// assigned ID — Archive/Unarchive/Delete reject entities without one
// (UnableToDeleteWithoutIDNotification), so the fixture mimics what
// FindByID would yield in production.
func buildValidUser(t *testing.T) *appdomain.User {
	t.Helper()
	u := validUser()
	u.SetID(domain.NewRandomID())
	u.AddAddress(validAddress(), nil)
	return u
}

func TestUser_BuildRules_Archive_NoPrincipal_Allows(t *testing.T) {
	// Auth disabled / no principal attached → degraded "trust" mode, no
	// owner-check fires. Mirrors the dev profile.
	u := buildValidUser(t)
	_, err := domain.GetArchivable(u, nil, "GetArchivable")
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
	_, err := domain.GetArchivable(u, nil, "GetArchivable")
	if err != nil {
		t.Errorf("archive must succeed when principal email matches owner, got: %v", err)
	}
}

func TestUser_BuildRules_Archive_PrincipalIsAdmin_Allows(t *testing.T) {
	u := buildValidUser(t)
	u.RequestingPrincipalEmail = "admin@example.com" // different email
	u.RequestingPrincipalIsAdmin = true              // admin bypass
	_, err := domain.GetArchivable(u, nil, "GetArchivable")
	if err != nil {
		t.Errorf("archive must succeed for admin even when emails differ, got: %v", err)
	}
}

func TestUser_BuildRules_Archive_NonOwnerNonAdmin_Rejects(t *testing.T) {
	u := buildValidUser(t)
	u.RequestingPrincipalEmail = "intruder@example.com"
	u.RequestingPrincipalIsAdmin = false
	_, err := domain.GetArchivable(u, nil, "GetArchivable")
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
	_, err := domain.GetUpdatable(u, func(*appdomain.User) error { return nil }, nil, "GetUpdatable")
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
	u := validUser()
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeInsert, nil)
	if !ok {
		t.Fatalf("expected validation to pass, got: %s", dumpContexts(ctxs))
	}
}

func TestUser_BuildRules_NameRequired(t *testing.T) {
	u := validUser()
	u.Name = ""
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeInsert, nil)
	if ok {
		t.Fatal("expected validation to fail")
	}
	if !hasNotification(ctxs, "name", "RequiredFieldNotification") {
		t.Fatalf("expected RequiredFieldNotification on name; got %s", dumpContexts(ctxs))
	}
}

func TestUser_BuildRules_EmailRequired(t *testing.T) {
	u := validUser()
	u.Email = ""
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeInsert, nil)
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
			u := validUser()
			u.Email = c.email
			u.AddAddress(validAddress(), nil)

			ok, ctxs := domain.IsValid(u, domain.ModeInsert, nil)
			if ok {
				t.Fatalf("expected validation to fail for %q", c.email)
			}
			if !hasNotification(ctxs, "email", "InvalidEmailNotification") {
				t.Fatalf("expected InvalidEmailNotification on email; got %s", dumpContexts(ctxs))
			}
		})
	}
}

// ─── Document (the natural key) validation ────────────────────────────────────

func TestUser_BuildRules_DocumentRequired(t *testing.T) {
	u := validUser()
	u.Document = ""
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeInsert, nil)
	if ok {
		t.Fatal("expected validation to fail when document is empty")
	}
	if !hasNotification(ctxs, "document", "RequiredFieldNotification") {
		t.Fatalf("expected RequiredFieldNotification on document; got %s", dumpContexts(ctxs))
	}
}

func TestUser_BuildRules_DocumentInvalid(t *testing.T) {
	cases := []struct {
		name string
		doc  string
	}{
		{"too short", "ab"},
		{"illegal char", "doc 123"},
		{"too long", strings.Repeat("9", 33)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			u := validUser()
			u.Document = c.doc
			u.AddAddress(validAddress(), nil)

			ok, ctxs := domain.IsValid(u, domain.ModeInsert, nil)
			if ok {
				t.Fatalf("expected validation to fail for document %q", c.doc)
			}
			if !hasNotification(ctxs, "document", "InvalidDocumentNotification") {
				t.Fatalf("expected InvalidDocumentNotification on document; got %s", dumpContexts(ctxs))
			}
		})
	}
}

func TestUser_BuildRules_UserNameRequired(t *testing.T) {
	u := validUser()
	u.UserName = ""
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeInsert, nil)
	if ok {
		t.Fatal("expected validation to fail when userName is empty")
	}
	if !hasNotification(ctxs, "userName", "RequiredFieldNotification") {
		t.Fatalf("expected RequiredFieldNotification on userName; got %s", dumpContexts(ctxs))
	}
}

// Notification preference flags are optional (*bool) — a nil pair is valid and
// the framework simply does not materialize the user_configurations sibling.
func TestUser_BuildRules_NotificationFlagsOptional(t *testing.T) {
	u := validUser()
	u.EmailNotification = nil
	u.SmsNotification = nil
	u.AddAddress(validAddress(), nil)
	if ok, ctxs := domain.IsValid(u, domain.ModeInsert, nil); !ok {
		t.Fatalf("expected validation to pass with nil notification flags; got %s", dumpContexts(ctxs))
	}

	u2 := validUser()
	u2.EmailNotification = bptr(true)
	u2.SmsNotification = bptr(false)
	u2.AddAddress(validAddress(), nil)
	if ok, ctxs := domain.IsValid(u2, domain.ModeInsert, nil); !ok {
		t.Fatalf("expected validation to pass with set notification flags; got %s", dumpContexts(ctxs))
	}
}

func TestUser_BuildRules_PhoneOptional_NilPasses(t *testing.T) {
	u := validUser()
	u.Phone = nil
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeInsert, nil)
	if !ok {
		t.Fatalf("expected validation to pass; got %s", dumpContexts(ctxs))
	}
}

func TestUser_BuildRules_PhoneOptional_EmptyStringPasses(t *testing.T) {
	// web/requests/ does not normalize empty string to nil (Request shape
	// identical to Command, no NilIfEmpty at the boundary). BuildRules
	// short-circuits when *Phone == "" and tolerates the empty pointer.
	empty := ""
	u := validUser()
	u.Phone = &empty
	u.AddAddress(validAddress(), nil)

	ok, ctxs := domain.IsValid(u, domain.ModeInsert, nil)
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
			u := validUser()
			u.Phone = ptr(c.phone)
			u.AddAddress(validAddress(), nil)

			ok, ctxs := domain.IsValid(u, domain.ModeInsert, nil)
			if ok {
				t.Fatalf("expected validation to fail for %q", c.phone)
			}
			if !hasNotification(ctxs, "phone", "InvalidPhoneNotification") {
				t.Fatalf("expected InvalidPhoneNotification on phone; got %s", dumpContexts(ctxs))
			}
		})
	}
}

// ─── AddAddress invariants ────────────────────────────────────────────────────

func TestUser_AddAddress_AcceptsDistinct(t *testing.T) {
	u := validUser()
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
	u := validUser()
	a := validAddress()
	dup := validAddress()
	// Different label but same Country+ZIP+Street+Number → same business identity.
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
	if _, err := domain.GetInsertable(u, nil, "GetInsertable"); err == nil {
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

// ─── Document immutability (transition-aware invariant via domain.Old) ────────
//
// Document is the natural key of the shared Person identity, so it is immutable.
// These tests exercise the canonical use case of domain.Old[T]: comparing the
// pre-mutation state (snapshotted by the framework's Get* path) against the
// post-mutation state inside BuildRules.

func TestUser_DocumentImmutable_RejectsChangeOnUpdate(t *testing.T) {
	u := buildValidUser(t)
	apply := func(x *appdomain.User) error { x.Document = "99999999999"; return nil }

	_, err := domain.GetUpdatable(u, apply, nil, "GetUpdatable")
	if err == nil {
		t.Fatal("expected GetUpdatable to fail when document is changed (immutable rule)")
	}
	var carrier domain.NotificationCarrier
	if !asCarrier(err, &carrier) {
		t.Fatalf("expected NotificationCarrier error; got %v", err)
	}
	if !hasNotification(carrier.NotificationContexts(), "document", "DocumentCannotChangeNotification") {
		t.Fatalf("expected DocumentCannotChangeNotification on document; got %s",
			dumpContexts(carrier.NotificationContexts()))
	}
}

func TestUser_DocumentImmutable_FiresOnPartialUpdateToo(t *testing.T) {
	u := buildValidUser(t)
	apply := func(x *appdomain.User) error { x.Document = "88888888888"; return nil }

	_, err := domain.GetPartialUpdatable(u, apply, nil, "GetPartialUpdatable")
	if err == nil {
		t.Fatal("expected GetPartialUpdatable to fail when document is changed")
	}
	var carrier domain.NotificationCarrier
	if !asCarrier(err, &carrier) {
		t.Fatalf("expected NotificationCarrier error; got %v", err)
	}
	if !hasNotification(carrier.NotificationContexts(), "document", "DocumentCannotChangeNotification") {
		t.Fatalf("expected DocumentCannotChangeNotification on document; got %s",
			dumpContexts(carrier.NotificationContexts()))
	}
}

func TestUser_DocumentImmutable_NoOpOnInsert(t *testing.T) {
	// Insert has no previous state (domain.Old returns nil) — the rule must
	// short-circuit and let any valid document through.
	u := validUser()
	u.AddAddress(validAddress(), nil)
	if _, err := domain.GetInsertable(u, nil, "GetInsertable"); err != nil {
		t.Fatalf("expected GetInsertable to pass on a fresh user; got %v", err)
	}
}

// Email is NOW a plain mutable shared field (no longer the identity) — changing
// it on Update must be allowed, in contrast with the immutable document.
func TestUser_Email_MutableOnUpdate(t *testing.T) {
	u := buildValidUser(t)
	apply := func(x *appdomain.User) error { x.Email = "jane.new@example.com"; return nil }
	if _, err := domain.GetUpdatable(u, apply, nil, "GetUpdatable"); err != nil {
		t.Fatalf("expected GetUpdatable to pass when only email changes; got %v", err)
	}
}
