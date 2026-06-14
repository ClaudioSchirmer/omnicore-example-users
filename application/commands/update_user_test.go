package commands

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

func TestUpdateUserCommand_FromEntity(t *testing.T) {
	id := domain.NewRandomID()
	u := &appdomain.User{Name: "Bob", Email: "b@x.com"}
	u.SetID(id)

	got := UpdateUserCommand{}.FromEntity(nil, u)

	if got.ID != id {
		t.Errorf("ID mismatch: got %v, want %v", got.ID, id)
	}
	if got.Name != "Bob" || got.Email != "b@x.com" {
		t.Errorf("scalar fields not transferred: %+v", got)
	}
}
