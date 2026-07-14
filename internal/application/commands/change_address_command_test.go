package commands

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/google/uuid"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// loadedUserWithAddress returns a User in CONSTRUCTOR state (mirrors the
// "loaded from DB" snapshot the framework's AggregateLoader produces) with
// one Address attached. The address ID lets the tests verify both the
// happy-path mutation and the not-found path without touching a database.
func loadedUserWithAddress(addressID string) *appdomain.User {
	phone := "14155552671"
	u := &appdomain.User{
		Name:  "Jane Doe",
		Email: "jane@example.com",
		Phone: &phone,
	}
	u.SetID(domain.NewID(uuid.NewString()))
	u.AggregateConstructor([]domain.AggregateValueObject{
		appdomain.Address{
			ID:           domain.NewID(addressID),
			Street:       "1 Audit Way",
			Number:       "1",
			Neighborhood: "Downtown",
			City:         "San Francisco",
			State:        "CA",
			ZipCode:      "94103",
			Country:      "US",
		},
	})
	return u
}

func TestChangeAddressCommand_ApplyTo_MutatesMatchingChild(t *testing.T) {
	addressID := uuid.NewString()
	u := loadedUserWithAddress(addressID)
	newLabel := "office"
	cmd := &ChangeAddressCommand{
		AddressID: addressID,
		Address: dtos.AddressInput{
			Label:        &newLabel,
			Street:       "2 Update Lane",
			Number:       "2",
			Neighborhood: "SoMa",
			City:         "San Francisco",
			State:        "CA",
			ZipCode:      "94110",
			Country:      "US",
		},
	}

	cmd.ApplyTo(nil, u)

	// Status of the slot must flip to CHANGED.
	changed := domain.GetChangedItemsOf[appdomain.Address](&u.AggregateRoot)
	if len(changed) != 1 {
		t.Fatalf("expected 1 CHANGED address, got %d", len(changed))
	}
	if changed[0].GetID().Value() != addressID {
		t.Errorf("expected CHANGED entry to keep same ID, got %q", changed[0].GetID())
	}
	if changed[0].Street != "2 Update Lane" {
		t.Errorf("expected new Street value, got %q", changed[0].Street)
	}
}

func TestChangeAddressCommand_ApplyTo_UnknownAddressIDEmitsNotFound(t *testing.T) {
	u := loadedUserWithAddress(uuid.NewString())
	cmd := &ChangeAddressCommand{
		AddressID: "00000000-0000-0000-0000-000000000000",
		Address: dtos.AddressInput{
			Street:       "irrelevant",
			Number:       "1",
			Neighborhood: "x",
			City:         "x",
			State:        "CA",
			ZipCode:      "94103",
			Country:      "US",
		},
	}

	cmd.ApplyTo(nil, u)

	// No CHANGED status was flipped — the original slot stays untouched.
	if len(domain.GetChangedItemsOf[appdomain.Address](&u.AggregateRoot)) != 0 {
		t.Errorf("expected zero CHANGED addresses on miss")
	}

	// A RecordNotFoundNotification must have landed on the User's context so
	// the wire layer surfaces 404 via the kernel notification's Semantic().
	ctx := u.NotificationContext()
	if ctx == nil || !ctx.HasErrors() {
		t.Fatalf("expected RecordNotFoundNotification on miss")
	}
	var found bool
	for _, m := range ctx.Messages() {
		if _, ok := m.Notification.(domain.RecordNotFoundNotification); ok {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected RecordNotFoundNotification on miss; got %+v", ctx.Messages())
	}
}

// TestChangeAddressCommand_FromEntity_ProjectsTargetedAddress proves the
// post-refactor projection reads cmd.AddressID directly from the receiver
// — no transient field on the entity, no LastChangedAddressID workaround.
func TestChangeAddressCommand_FromEntity_ProjectsTargetedAddress(t *testing.T) {
	addressID := uuid.NewString()
	u := loadedUserWithAddress(addressID)
	cmd := &ChangeAddressCommand{AddressID: addressID}

	got, _ := cmd.FromEntity(nil, u)

	if got.UserID != *u.GetID() {
		t.Errorf("UserID mismatch: got %v, want %v", got.UserID, *u.GetID())
	}
	if got.Address.ID != addressID {
		t.Errorf("Address.ID mismatch: got %q, want %q", got.Address.ID, addressID)
	}
	if got.Address.Street != "1 Audit Way" {
		t.Errorf("Address.Street not transferred: %q", got.Address.Street)
	}
}

// TestChangeAddressCommand_FromEntity_EmptyOnUnknownID covers the defensive
// branch — projecting with a cmd.AddressID that doesn't match any child
// returns an empty AddressResult (rather than the first slot or a panic).
func TestChangeAddressCommand_FromEntity_EmptyOnUnknownID(t *testing.T) {
	u := loadedUserWithAddress(uuid.NewString())
	cmd := &ChangeAddressCommand{AddressID: "00000000-0000-0000-0000-000000000000"}

	got, _ := cmd.FromEntity(nil, u)

	if got.Address.ID != "" {
		t.Errorf("expected empty Address.ID when cmd targets unknown id, got %q", got.Address.ID)
	}
}
