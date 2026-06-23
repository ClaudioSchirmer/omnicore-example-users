package commands

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
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
