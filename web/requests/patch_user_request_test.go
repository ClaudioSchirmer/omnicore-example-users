package requests

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
)

func TestPatchUserRequest_ToCommand_AllSet(t *testing.T) {
	r := PatchUserRequest{
		Name:  strptr("X"),
		Email: strptr("y@z.w"),
		Phone: strptr("11999"),
	}
	cmd := r.ToCommand()
	if cmd.Name == nil || *cmd.Name != "X" {
		t.Errorf("Name not transferred")
	}
	if cmd.Email == nil || *cmd.Email != "y@z.w" {
		t.Errorf("Email not transferred")
	}
	if cmd.Phone == nil || *cmd.Phone != "11999" {
		t.Errorf("Phone not transferred")
	}
}

func TestPatchUserRequest_ToCommand_AllNil(t *testing.T) {
	r := PatchUserRequest{}
	cmd := r.ToCommand()
	if cmd.Name != nil || cmd.Email != nil || cmd.Phone != nil {
		t.Errorf("expected all nil, got %+v", cmd)
	}
}

func TestPatchUserRequest_ToCommand_PartialSet(t *testing.T) {
	r := PatchUserRequest{Name: strptr("OnlyName")}
	cmd := r.ToCommand()
	if cmd.Name == nil || *cmd.Name != "OnlyName" {
		t.Errorf("Name not transferred")
	}
	if cmd.Email != nil {
		t.Errorf("Email should remain nil")
	}
	if cmd.Phone != nil {
		t.Errorf("Phone should remain nil")
	}
}

func TestPatchUserRequest_ToCommand_PhoneEmptyStringPreserved(t *testing.T) {
	empty := ""
	r := PatchUserRequest{Phone: &empty}
	cmd := r.ToCommand()
	if cmd.Phone == nil || *cmd.Phone != "" {
		t.Errorf("expected *'', got %v", cmd.Phone)
	}
}

// ─── Output: FromResult ──────────────────────────────────────────────────────

func TestPatchUserResponse_FromResult(t *testing.T) {
	id := domain.NewRandomID()
	phone := "11888888888"
	r := commands.PatchUserResult{ID: id, Name: "Carol", Email: "c@x.com", Phone: &phone}

	resp := PatchUserResponse{}.FromResult(r)

	if resp.ID != id {
		t.Errorf("ID mismatch: got %v, want %v", resp.ID, id)
	}
	if resp.Name != "Carol" || resp.Email != "c@x.com" {
		t.Errorf("scalar fields not transferred: %+v", resp)
	}
	if resp.Phone == nil || *resp.Phone != "11888888888" {
		t.Errorf("Phone not transferred: %v", resp.Phone)
	}
}
