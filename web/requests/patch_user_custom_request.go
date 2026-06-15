package requests

import "github.com/ClaudioSchirmer/omnicore-example-users/application/commands"

// PatchUserCustomRequest is the wire shape of
// PATCH /showcase/users-custom/:email. Mirrors PatchUserCustomCommand 1:1.
//
// Email carries no `json` tag — its value comes from the URL segment via
// `path:"email"`. Same rationale documented on UpdateUserCustomRequest:
// the /:email segment is the identifier, not a body data field. Address
// operations are NOT patchable here; use PUT to replace the collection.
type PatchUserCustomRequest struct {
	Email string  `path:"email"`
	Name  *string `json:"name,omitempty"  example:"Alice Pereira"`
	Phone *string `json:"phone,omitempty" example:"14155552671"`
}

// ToCommand converts the Request DTO into the Command. EmailKey comes from
// req.Email — populated by fwweb.BindPath from the /:email URL segment
// before c.Bind().Body().
func (r PatchUserCustomRequest) ToCommand() *commands.PatchUserCustomCommand {
	return &commands.PatchUserCustomCommand{
		EmailKey: r.Email,
		Name:     r.Name,
		Phone:    r.Phone,
	}
}
