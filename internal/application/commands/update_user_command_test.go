package commands

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

func TestUpdateUserCommand_FromEntity(t *testing.T) {
	id := domain.NewRandomID()
	u := &appdomain.User{Name: "Bob", Email: "b@x.com"}
	u.SetID(id)

	got, _ := UpdateUserCommand{}.FromEntity(nil, u)

	if got.ID != id {
		t.Errorf("ID mismatch: got %v, want %v", got.ID, id)
	}
	if got.Name != "Bob" || got.Email != "b@x.com" {
		t.Errorf("scalar fields not transferred: %+v", got)
	}
}

// The PUT replaces the whole address collection — its Result mirrors the
// post-write set, ids included (AssignAggregateItemID stands in for the
// persister's write-back of the minted child PK).
func TestUpdateUserCommand_FromEntity_MirrorsAddressesWithIDs(t *testing.T) {
	addr := appdomain.Address{
		Street: "Elm", Number: "9", Neighborhood: "Center",
		City: "Austin", State: "TX", ZipCode: "73301", Country: "US",
	}
	u := &appdomain.User{Name: "Bob", Email: "b@x.com"}
	u.SetID(domain.NewRandomID())
	u.AddAddress(addr, nil)
	if ok := u.AssignAggregateItemID(addr, "addr-9"); !ok {
		t.Fatal("test setup: the id write-back must find the tracked address")
	}

	got, _ := UpdateUserCommand{}.FromEntity(nil, u)

	if len(got.Addresses) != 1 || got.Addresses[0].ID != "addr-9" {
		t.Fatalf("expected the mirrored address with its persisted id, got %+v", got.Addresses)
	}
}
