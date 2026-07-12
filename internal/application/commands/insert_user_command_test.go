package commands

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// InsertUserCommand.FromEntity is the canonical projection — Result lives as
// pure data; the Command owns input + output mapping. Tests call FromEntity
// on the Command (with nil ctx for the simple cases — none of the projections
// here consume ctx).

func TestInsertUserCommand_FromEntity(t *testing.T) {
	id := domain.NewRandomID()
	phone := "11999"
	u := &appdomain.User{Name: "Alice", Email: "a@x.com", Phone: &phone}
	u.SetID(id)

	got, _ := InsertUserCommand{}.FromEntity(nil, u)

	if got.ID != id {
		t.Errorf("ID mismatch: got %v, want %v", got.ID, id)
	}
	if got.Name != "Alice" || got.Email != "a@x.com" {
		t.Errorf("scalar fields not transferred: %+v", got)
	}
	if got.Phone == nil || *got.Phone != "11999" {
		t.Errorf("Phone not transferred: %v", got.Phone)
	}
}

func TestInsertUserCommand_FromEntity_NilPhone(t *testing.T) {
	u := &appdomain.User{Name: "x", Email: "y@z.w"} // Phone nil
	u.SetID(domain.NewRandomID())

	got, _ := InsertUserCommand{}.FromEntity(nil, u)

	if got.Phone != nil {
		t.Errorf("expected nil Phone, got %v", got.Phone)
	}
}

// The insert Result is the FULL aggregate mirror: every current address rides
// along, id included. AssignAggregateItemID stands in for the persister's
// write-back (post-write, the minted child PK is stamped back into the
// aggregate map — that is what FromEntity reads).
func TestInsertUserCommand_FromEntity_MirrorsAddressesWithIDs(t *testing.T) {
	addr := appdomain.Address{
		Street: "Main", Number: "1", Neighborhood: "Downtown",
		City: "SF", State: "CA", ZipCode: "94103", Country: "US",
	}
	u := &appdomain.User{Name: "Alice", Email: "a@x.com"}
	u.SetID(domain.NewRandomID())
	u.AddAddress(addr, nil)
	if ok := u.AssignAggregateItemID(addr, "addr-1"); !ok {
		t.Fatal("test setup: the id write-back must find the tracked address")
	}

	got, _ := InsertUserCommand{}.FromEntity(nil, u)

	if len(got.Addresses) != 1 {
		t.Fatalf("expected the mirrored address collection, got %+v", got.Addresses)
	}
	if got.Addresses[0].ID != "addr-1" {
		t.Errorf("mirrored address must carry the persisted id, got %q", got.Addresses[0].ID)
	}
	if got.Addresses[0].Street != "Main" || got.Addresses[0].Country != "US" {
		t.Errorf("mirrored address data mismatch: %+v", got.Addresses[0])
	}
}
