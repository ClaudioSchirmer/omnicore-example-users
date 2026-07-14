package handlers

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/google/uuid"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// TestInsertUserCustomCommandHandler_HappyPath proves the manual SharedBase
// upsert chain on a COLD insert (no pre-existing person): ApplyTo (read key) →
// LoadForSharedBaseInsert (existed=false) → GetInsertable("GetInsertable") →
// Insert → SetID → FromEntity → a UserCustomResult with a populated ID and
// exactly one Repo.Insert call.
func TestInsertUserCustomCommandHandler_HappyPath(t *testing.T) {
	repo := &fakeRepo{} // foundUser nil → cold insert
	h := &InsertUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	cmd := &commands.InsertUserCustomCommand{
		Name:     "Jane Doe",
		Email:    "jane@example.com",
		Document: "10000000001",
		UserName: "jane",
		Addresses: []dtos.AddressInputCustom{{
			Street:       "1 Infinite Loop",
			Number:       "1",
			Neighborhood: "Mariani",
			City:         "Cupertino",
			State:        "CA",
			ZipCode:      "95014",
			Country:      "US",
		}},
	}

	result, err := h.Handle(testCtx(), cmd)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.ID.IsEmpty() {
		t.Error("expected result to have an ID populated by SetID before FromEntity")
	}
	if result.Name != "Jane Doe" || result.Email != "jane@example.com" {
		t.Errorf("unexpected result fields: %+v", result)
	}
	if result.Document != "10000000001" || result.UserName != "jane" {
		t.Errorf("expected document/userName projected onto the result: %+v", result)
	}
	if len(result.Addresses) != 1 {
		t.Errorf("expected 1 address projected onto the result, got %d", len(result.Addresses))
	}
	if repo.insertCalled != 1 {
		t.Errorf("expected Insert called once, got %d", repo.insertCalled)
	}
}

// TestInsertUserCustomCommandHandler_WarmUpsert proves the WARM path: when the
// person already exists (seeded via foundUser), LoadForSharedBaseInsert reports
// existed=true, the handler re-applies the request onto the loaded identity and
// switches the actionName to "GetUpsertable", then inserts. The request's fields
// win (last-write-wins) on the projected result.
func TestInsertUserCustomCommandHandler_WarmUpsert(t *testing.T) {
	// The loaded shared identity carries the base fields + the person's existing
	// addresses as Constructor items, but NO role id — LoadSharedBaseIdentity
	// loads the base by natural key, and the role id is generated
	// only at the write layer. An id here would (correctly) trip
	// UnableToInsertWithIDNotification.
	existing := &appdomain.User{
		Name:     "Jane Doe",
		Email:    "jane@example.com",
		Document: "10000000001",
		UserName: "jane",
	}
	existing.AggregateConstructor([]domain.AggregateValueObject{
		appdomain.Address{
			ID: domain.NewID(uuid.NewString()), Street: "1 Infinite Loop", Number: "1",
			Neighborhood: "Mariani", City: "Cupertino", State: "CA",
			ZipCode: "95014", Country: "US",
		},
	})
	repo := &fakeRepo{foundUser: existing}
	h := &InsertUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	cmd := &commands.InsertUserCustomCommand{
		Name:     "Jane Renamed",
		Email:    "jane.new@example.com",
		Document: "10000000001",
		UserName: "jane2",
	}

	result, err := h.Handle(testCtx(), cmd)
	if err != nil {
		t.Fatalf("unexpected error on warm upsert: %v", err)
	}
	if result.Name != "Jane Renamed" || result.Email != "jane.new@example.com" {
		t.Errorf("expected request fields to win on warm upsert (last-write-wins): %+v", result)
	}
	if repo.insertCalled != 1 {
		t.Errorf("expected Insert called once on warm upsert, got %d", repo.insertCalled)
	}
}

// TestInsertUserCustomCommandHandler_PropagatesValidationError surfaces a
// BuildRules rejection: an empty email triggers a notification, GetInsertable
// returns a *DomainError, and the handler returns it unchanged so the wire
// layer converts to 422. The Repo must NOT be written to when validation fails.
func TestInsertUserCustomCommandHandler_PropagatesValidationError(t *testing.T) {
	repo := &fakeRepo{}
	h := &InsertUserCustomCommandHandler{Repo: repo, Service: fakeService{}}

	cmd := &commands.InsertUserCustomCommand{Name: "X", Email: "", Document: "10000000001", UserName: "x"}

	_, err := h.Handle(testCtx(), cmd)
	if err == nil {
		t.Fatal("expected validation error for empty email")
	}
	if repo.insertCalled != 0 {
		t.Errorf("expected Insert NOT called on validation failure, got %d", repo.insertCalled)
	}
}
