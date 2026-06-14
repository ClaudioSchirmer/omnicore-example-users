package requests

import (
	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	"github.com/ClaudioSchirmer/omnicore-example-users/application/dtos"
)

// UpdateUserCustomRequest is the wire shape of
// PUT /showcase/users-custom/:email. Mirrors UpdateUserCustomCommand 1:1.
//
// Email carries no `json` tag — its value comes from the URL segment via
// the `path:"email"` tag, not from the body. The custom route chains
// fwweb.BindPath(c, &req) before BodyParser so the framework reads
// c.Params("email") into req.Email, then ToCommand maps it to
// cmd.EmailKey. Letting Email also live in the body would create three
// confusing options (URL = old + body = new → silent rename; URL must ==
// body → useless duplication; URL wins + body ignored → contract lie),
// so the surface treats /:email as the immutable key. To rename, hit
// DELETE then POST. The canonical PUT /users/:id (UUID-keyed) continues
// to allow email mutation.
//
// The manual route does NOT enforce the FullBody strict-body check the
// canonical PUT applies — body parsing is plain BodyParser, and the
// dispatching handler accepts whatever the consumer sent. Missing fields
// are domain-rejected via BuildRules (422), not wire-rejected (400).
type UpdateUserCustomRequest struct {
	Email     string                 `path:"email"`
	Name      string                 `json:"name"            example:"Alice Pereira"`
	Phone     *string                `json:"phone,omitempty" example:"14155552671"`
	Addresses []AddressCustomRequest `json:"addresses"`
}

// ToCommand converts the Request DTO into the Command. EmailKey comes from
// req.Email — populated by fwweb.BindPath from the /:email URL segment
// before BodyParser. The route no longer assigns cmd.EmailKey manually;
// path-binding owns the wire boundary, and ToCommand owns the
// application-side mapping.
func (r UpdateUserCustomRequest) ToCommand() *commands.UpdateUserCustomCommand {
	addrs := make([]dtos.AddressInputCustom, len(r.Addresses))
	for i, a := range r.Addresses {
		addrs[i] = a.ToAddressInput()
	}
	return &commands.UpdateUserCustomCommand{
		EmailKey:  r.Email,
		Name:      r.Name,
		Phone:     r.Phone,
		Addresses: addrs,
	}
}
