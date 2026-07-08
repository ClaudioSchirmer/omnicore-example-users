package requests

import (
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// InsertUserCustomRequest is the JSON wire shape of
// POST /showcase/users-custom/. Mirrors InsertUserCustomCommand 1:1
// (Name/Email mandatory; Phone/Addresses optional). Same shape as the
// canonical InsertUserRequest — the dedicated symbol exists so the
// manual showcase keeps every layer above domain/ as a parallel copy,
// matching the Update/Patch/Archive/Unarchive/Delete custom twins.
type InsertUserCustomRequest struct {
	Name              string                 `json:"name"                        example:"Alice Pereira"`
	Email             string                 `json:"email"                       example:"alice@example.com"`
	Phone             *string                `json:"phone,omitempty"             example:"14155552671"`
	Document          string                 `json:"document"                    example:"12345678901"`
	UserName          string                 `json:"userName"                    example:"alice"`
	EmailNotification *bool                  `json:"emailNotification,omitempty" example:"true"`
	SmsNotification   *bool                  `json:"smsNotification,omitempty"   example:"false"`
	Addresses         []AddressCustomRequest `json:"addresses,omitempty"`
}

// ToCommand converts the Request DTO into the Command. Boundary
// web→application: pure body assignment with no normalization. Address
// children are mapped via AddressCustomRequest.ToAddressInput (also 1:1).
// AppContext does NOT enter here — identity-derived translation belongs
// to the application layer (Command.ApplyTo receives ctx).
func (r InsertUserCustomRequest) ToCommand() *commands.InsertUserCustomCommand {
	addrs := make([]dtos.AddressInputCustom, len(r.Addresses))
	for i, a := range r.Addresses {
		addrs[i] = a.ToAddressInput()
	}
	return &commands.InsertUserCustomCommand{
		Name:              r.Name,
		Email:             r.Email,
		Phone:             r.Phone,
		Document:          r.Document,
		UserName:          r.UserName,
		EmailNotification: r.EmailNotification,
		SmsNotification:   r.SmsNotification,
		Addresses:         addrs,
	}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────
//
// No Response DTO is co-located with this Request. The manual showcase
// emits the full-body responses.UserCustomResponse (via FromUserCustom(*appdomain.User))
// for every write — see web/responses/user_custom_response.go. The canonical
// surface's per-endpoint Result/Response pair (InsertUserResult +
// InsertUserResponse) is intentionally not mirrored here because the
// custom InsertUserCustomCommandHandler returns *appdomain.User directly, not a
// Result projection.
