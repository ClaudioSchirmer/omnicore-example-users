package requests

import (
	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	"github.com/ClaudioSchirmer/omnicore-example-users/application/dtos"
)

// UpdateUserCustomRequest is the wire shape of
// PUT /showcase/users-custom/:document. Mirrors UpdateUserCustomCommand 1:1.
//
// Document carries no `json` tag — its value comes from the URL segment via
// the `path:"document"` tag, not from the body. The custom route chains
// fwweb.BindPath(c, &req) before c.Bind().Body() so the framework reads
// c.Params("document") into req.Document, then ToCommand maps it to
// cmd.DocumentKey. Document is the immutable natural key (it cannot be renamed
// on any surface), so keeping it out of the body avoids the URL-vs-body
// ambiguity. Email, by contrast, IS editable here — it is now a plain mutable
// shared field, not the key.
//
// The manual route does NOT enforce the FullBody strict-body check the
// canonical PUT applies — body parsing is plain c.Bind().Body(), and the
// dispatching handler accepts whatever the consumer sent. Missing fields
// are domain-rejected via BuildRules (422), not wire-rejected (400).
type UpdateUserCustomRequest struct {
	Document          string                 `path:"document"`
	Name              string                 `json:"name"                        example:"Alice Pereira"`
	Email             string                 `json:"email"                       example:"alice@example.com"`
	Phone             *string                `json:"phone,omitempty"             example:"14155552671"`
	UserName          string                 `json:"userName"                    example:"alice"`
	EmailNotification *bool                  `json:"emailNotification,omitempty" example:"true"`
	SmsNotification   *bool                  `json:"smsNotification,omitempty"   example:"false"`
	Addresses         []AddressCustomRequest `json:"addresses"`
}

// ToCommand converts the Request DTO into the Command. DocumentKey comes from
// req.Document — populated by fwweb.BindPath from the /:document URL segment
// before c.Bind().Body(). The route no longer assigns cmd.DocumentKey manually;
// path-binding owns the wire boundary, and ToCommand owns the
// application-side mapping.
func (r UpdateUserCustomRequest) ToCommand() *commands.UpdateUserCustomCommand {
	addrs := make([]dtos.AddressInputCustom, len(r.Addresses))
	for i, a := range r.Addresses {
		addrs[i] = a.ToAddressInput()
	}
	return &commands.UpdateUserCustomCommand{
		DocumentKey:       r.Document,
		Name:              r.Name,
		Email:             r.Email,
		Phone:             r.Phone,
		UserName:          r.UserName,
		EmailNotification: r.EmailNotification,
		SmsNotification:   r.SmsNotification,
		Addresses:         addrs,
	}
}
