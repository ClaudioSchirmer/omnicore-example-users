package commands

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/google/uuid"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/dtos"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// ─── Canonical commands ────────────────────────────────────────────────────

func TestInsertUserCommand_ToEntity_CopiesFieldsAndAddresses(t *testing.T) {
	phone := "11999"
	cmd := InsertUserCommand{
		Name:  "Alice",
		Email: "a@x.com",
		Phone: &phone,
		Addresses: []dtos.AddressInput{
			{Street: "St 1", Number: "1", Neighborhood: "N", City: "C", State: "ST", ZipCode: "00000", Country: "BR"},
		},
	}
	u := cmd.ToEntity(nil)
	if u.Name != "Alice" || u.Email != "a@x.com" {
		t.Errorf("entity fields = %+v", u)
	}
	if u.Phone == nil || *u.Phone != "11999" {
		t.Errorf("Phone = %v", u.Phone)
	}
	addrs := domain.GetCurrentItemsOf[appdomain.Address](&u.AggregateRoot)
	if len(addrs) != 1 || addrs[0].Street != "St 1" {
		t.Errorf("addresses not propagated: %+v", addrs)
	}
}

func TestUpdateUserCommand_ApplyTo_ReplacesRootAndAddresses(t *testing.T) {
	// Seed user with one existing address.
	u := &appdomain.User{Name: "Old", Email: "old@x.com"}
	domain.EnsureInitialized(u)
	u.SetID(domain.NewID(uuid.NewString()))
	u.AggregateConstructor([]domain.AggregateValueObject{
		appdomain.Address{ID: "a1", Street: "Old", Number: "1", Neighborhood: "N",
			City: "C", State: "ST", ZipCode: "0", Country: "BR"},
	})

	phone := "555"
	cmd := UpdateUserCommand{
		Name:  "New",
		Email: "new@x.com",
		Phone: &phone,
		Addresses: []dtos.AddressInput{
			{Street: "S2", Number: "2", Neighborhood: "N2", City: "C2", State: "ST2", ZipCode: "10000", Country: "BR"},
		},
	}
	cmd.ApplyTo(nil, u)

	if u.Name != "New" || u.Email != "new@x.com" || *u.Phone != "555" {
		t.Errorf("root fields not replaced: %+v", u)
	}
	current := domain.GetCurrentItemsOf[appdomain.Address](&u.AggregateRoot)
	if len(current) != 1 || current[0].Street != "S2" {
		t.Errorf("address collection not replaced, got %+v", current)
	}
}

// UpdateUserCommand.FromEntity already covered by update_user_test.go.

func TestPatchUserCommand_ApplyPartiallyTo_OnlyMutatesNonNil(t *testing.T) {
	old := "Old"
	oldEmail := "old@x"
	oldPhone := "111"
	u := &appdomain.User{Name: old, Email: oldEmail, Phone: &oldPhone}
	u.SetID(domain.NewRandomID())

	// Only Name set — Email/Phone preserved.
	newName := "New"
	cmd := &PatchUserCommand{Name: &newName}
	cmd.ApplyPartiallyTo(nil, u)
	if u.Name != "New" {
		t.Errorf("Name = %q", u.Name)
	}
	if u.Email != "old@x" {
		t.Errorf("Email should not change: %q", u.Email)
	}
	if u.Phone == nil || *u.Phone != "111" {
		t.Errorf("Phone should not change, got %v", u.Phone)
	}

	// Now set Email + clear Phone (nil → no change still).
	newEmail := "new@x"
	cmd2 := &PatchUserCommand{Email: &newEmail}
	cmd2.ApplyPartiallyTo(nil, u)
	if u.Email != "new@x" {
		t.Errorf("Email = %q", u.Email)
	}

	// PatchUserCommand.ApplyPartiallyTo replaces u.Phone = c.Phone when non-nil.
	newPhone := "222"
	cmd3 := &PatchUserCommand{Phone: &newPhone}
	cmd3.ApplyPartiallyTo(nil, u)
	if u.Phone == nil || *u.Phone != "222" {
		t.Errorf("Phone = %v", u.Phone)
	}
}

// PatchUserCommand.FromEntity already covered by patch_user_test.go.

// ─── Bodyless verbs (Archive/Unarchive/Delete) ────────────────────────────

func TestArchiveUserCommand_ApplyTo_PopulatesTransientsFromIdentity(t *testing.T) {
	u := &appdomain.User{}
	ctx := configuration.NewAppContextWithRandomID(configuration.LangENG)
	ctx.SetIdentity(&configuration.Identity{
		Claims: map[string]any{
			"email":       "owner@x",
			"permissions": []any{"users:admin"},
		},
	})

	(&ArchiveUserCommand{}).ApplyTo(ctx, u)
	if u.RequestingPrincipalEmail != "owner@x" {
		t.Errorf("RequestingPrincipalEmail = %q", u.RequestingPrincipalEmail)
	}
	if !u.RequestingPrincipalIsAdmin {
		t.Error("RequestingPrincipalIsAdmin should be true when users:admin in claims")
	}
}

func TestArchiveUserCommand_ApplyTo_NilCtxIsSafe(t *testing.T) {
	u := &appdomain.User{}
	(&ArchiveUserCommand{}).ApplyTo(nil, u)
	if u.RequestingPrincipalEmail != "" || u.RequestingPrincipalIsAdmin {
		t.Errorf("nil ctx should leave transients zero: %+v", u)
	}
}

func TestArchiveUserCommand_ApplyTo_NilIdentityIsSafe(t *testing.T) {
	u := &appdomain.User{}
	ctx := configuration.NewAppContextWithRandomID(configuration.LangENG)
	(&ArchiveUserCommand{}).ApplyTo(ctx, u)
	if u.RequestingPrincipalEmail != "" {
		t.Errorf("nil identity should leave transients zero, got %+v", u)
	}
}

func TestArchiveUserCommand_FromEntity_ReturnsNone(t *testing.T) {
	// fwresults.None has no observable fields; just exercise the path.
	(&ArchiveUserCommand{}).FromEntity(nil, &appdomain.User{})
}

func TestUnarchiveUserCommand_FromEntityAndApplyTo(t *testing.T) {
	u := &appdomain.User{}
	(&UnarchiveUserCommand{}).ApplyTo(nil, u)
	(&UnarchiveUserCommand{}).FromEntity(nil, u)
}

func TestDeleteUserCommand_FromEntityAndApplyTo(t *testing.T) {
	u := &appdomain.User{}
	(&DeleteUserCommand{}).ApplyTo(nil, u)
	(&DeleteUserCommand{}).FromEntity(nil, u)
}

// ─── Custom commands (manual showcase) ────────────────────────────────────

func TestInsertUserCustomCommand_ToEntityAndFromEntity(t *testing.T) {
	phone := "999"
	cmd := InsertUserCustomCommand{
		Name:  "Alice",
		Email: "a@x.com",
		Phone: &phone,
		Addresses: []dtos.AddressInputCustom{
			{Street: "S", Number: "1", Neighborhood: "N", City: "C", State: "ST", ZipCode: "0", Country: "BR"},
		},
	}
	u := cmd.ToEntity(nil)
	if u.Name != "Alice" || u.Email != "a@x.com" {
		t.Errorf("custom ToEntity root = %+v", u)
	}
	if got := domain.GetCurrentItemsOf[appdomain.Address](&u.AggregateRoot); len(got) != 1 {
		t.Errorf("custom ToEntity addresses = %v", got)
	}

	// FromEntity must populate ID via *u.GetID().
	u.SetID(domain.NewRandomID())
	res := cmd.FromEntity(nil, u)
	if res.Name != "Alice" || res.Email != "a@x.com" {
		t.Errorf("custom FromEntity = %+v", res)
	}
}

func TestUpdateUserCustomCommand_ApplyToReplacesAndDropsEmail(t *testing.T) {
	u := &appdomain.User{Name: "Old", Email: "kept@x"}
	domain.EnsureInitialized(u)
	u.SetID(domain.NewID(uuid.NewString()))

	cmd := &UpdateUserCustomCommand{
		EmailKey: "kept@x",
		Name:     "New",
		Phone:    nil,
		Addresses: []dtos.AddressInputCustom{
			{Street: "S", Number: "1", Neighborhood: "N", City: "C", State: "ST", ZipCode: "0", Country: "BR"},
		},
	}
	cmd.ApplyTo(nil, u)
	if u.Name != "New" {
		t.Errorf("Name not replaced: %q", u.Name)
	}
	// Email NOT replaced — surface drops it from the mutable shape.
	if u.Email != "kept@x" {
		t.Errorf("Email must stay immutable on custom surface, got %q", u.Email)
	}
	current := domain.GetCurrentItemsOf[appdomain.Address](&u.AggregateRoot)
	if len(current) != 1 {
		t.Errorf("addresses not replaced: %+v", current)
	}
}

func TestUpdateUserCustomCommand_FromEntity(t *testing.T) {
	u := &appdomain.User{Name: "N", Email: "e@x"}
	u.SetID(domain.NewRandomID())
	res := (&UpdateUserCustomCommand{}).FromEntity(nil, u)
	if res.Name != "N" {
		t.Errorf("res = %+v", res)
	}
}

func TestPatchUserCustomCommand_ApplyPartiallyTo(t *testing.T) {
	name0 := "Old"
	email0 := "kept@x"
	u := &appdomain.User{Name: name0, Email: email0}
	u.SetID(domain.NewID(uuid.NewString()))

	newName := "New"
	cmd := &PatchUserCustomCommand{EmailKey: email0, Name: &newName}
	cmd.ApplyPartiallyTo(nil, u)
	if u.Name != "New" || u.Email != "kept@x" {
		t.Errorf("patch custom: %+v", u)
	}

	// FromEntity exercises projection.
	(&PatchUserCustomCommand{}).FromEntity(nil, u)
}

func TestArchiveUserCustomCommand_ApplyAndFromEntity(t *testing.T) {
	u := &appdomain.User{}
	(&ArchiveUserCustomCommand{}).ApplyTo(nil, u)
	(&ArchiveUserCustomCommand{}).FromEntity(nil, u)
}

func TestUnarchiveUserCustomCommand_ApplyAndFromEntity(t *testing.T) {
	u := &appdomain.User{}
	(&UnarchiveUserCustomCommand{}).ApplyTo(nil, u)
	(&UnarchiveUserCustomCommand{}).FromEntity(nil, u)
}

func TestDeleteUserCustomCommand_ApplyAndFromEntity(t *testing.T) {
	u := &appdomain.User{}
	(&DeleteUserCustomCommand{}).ApplyTo(nil, u)
	(&DeleteUserCustomCommand{}).FromEntity(nil, u)
}

// ─── ChangeAddress custom ─────────────────────────────────────────────────

func TestChangeAddressCustomCommand_ApplyAndFromEntity(t *testing.T) {
	// Pre-seed root with one address; the cmd asks to change it.
	u := &appdomain.User{Name: "U", Email: "e@x"}
	domain.EnsureInitialized(u)
	u.SetID(domain.NewID(uuid.NewString()))
	u.AggregateConstructor([]domain.AggregateValueObject{
		appdomain.Address{ID: "addr-1", Street: "Old", Number: "1", Neighborhood: "N",
			City: "C", State: "ST", ZipCode: "0", Country: "BR"},
	})

	cmd := &ChangeAddressCustomCommand{
		EmailKey:  "e@x",
		AddressID: "addr-1",
		Address: dtos.AddressInputCustom{
			Street: "New", Number: "1", Neighborhood: "N", City: "C",
			State: "ST", ZipCode: "0", Country: "BR",
		},
	}
	// Apply mutates the loaded aggregate.
	cmd.ApplyTo(nil, u)
	current := domain.GetCurrentItemsOf[appdomain.Address](&u.AggregateRoot)
	if len(current) == 0 || current[0].Street != "New" {
		t.Errorf("ChangeAddress did not replace, got %+v", current)
	}

	// FromEntity returns the shared UserCustomResult.
	res := cmd.FromEntity(nil, u)
	if res.Email != "e@x" {
		t.Errorf("FromEntity = %+v", res)
	}
}
