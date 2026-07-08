package commands

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

func TestPatchUserCommand_FromEntity(t *testing.T) {
	id := domain.NewRandomID()
	phone := "11888"
	u := &appdomain.User{Name: "Carol", Email: "c@x.com", Phone: &phone}
	u.SetID(id)

	got, _ := (&PatchUserCommand{}).FromEntity(nil, u)

	if got.ID != id {
		t.Errorf("ID mismatch: got %v, want %v", got.ID, id)
	}
	if got.Name != "Carol" || got.Email != "c@x.com" {
		t.Errorf("scalar fields not transferred: %+v", got)
	}
	if got.Phone == nil || *got.Phone != "11888" {
		t.Errorf("Phone not transferred: %v", got.Phone)
	}
}
