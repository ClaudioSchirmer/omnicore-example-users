package requests

import (
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// InsertUserRequest is the JSON wire shape of POST /users. Shape identical
// to InsertUserCommand (Name/Email mandatory; Phone/Addresses optional).
// ToCommand is a 1:1 assignment.
type InsertUserRequest struct {
	Name              string           `json:"name"                        example:"Alice Pereira"`
	Email             string           `json:"email"                       example:"alice@example.com"`
	Phone             *string          `json:"phone,omitempty"             example:"14155552671"`
	Document          string           `json:"document"                    example:"12345678901"`
	UserName          string           `json:"userName"                    example:"alice"`
	EmailNotification *bool            `json:"emailNotification,omitempty" example:"true"`
	SmsNotification   *bool            `json:"smsNotification,omitempty"   example:"false"`
	Addresses         []AddressRequest `json:"addresses,omitempty"`
}

// ToCommand converts the Request DTO into the Command. Boundary
// web→application: pure body assignment with no normalization. Address
// children are mapped via AddressRequest.ToAddressInput (also 1:1).
// AppContext does NOT enter here — identity-derived translation belongs to
// the application layer (Command.ApplyTo receives ctx).
func (r InsertUserRequest) ToCommand() *commands.InsertUserCommand {
	addrs := make([]dtos.AddressInput, len(r.Addresses))
	for i, a := range r.Addresses {
		addrs[i] = a.ToAddressInput()
	}
	return &commands.InsertUserCommand{
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

// InsertUserResponse is the wire shape of POST /users on success. Carries
// the persisted entity's identity + root field snapshot — the framework
// dispatches via responseProjection (this struct's FromResult) and wraps the
// envelope around it.
type InsertUserResponse struct {
	ID                domain.ID `json:"id"                          example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name              string    `json:"name"                        example:"Alice Pereira"`
	Email             string    `json:"email"                       example:"alice@example.com"`
	Phone             *string   `json:"phone,omitempty"             example:"14155552671"`
	Document          string    `json:"document"                    example:"12345678901"`
	UserName          string    `json:"userName"                    example:"alice"`
	EmailNotification *bool     `json:"emailNotification,omitempty" example:"true"`
	SmsNotification   *bool     `json:"smsNotification,omitempty"   example:"false"`
}

// FromResult is the symmetric inverse of ToCommand — application Result →
// wire Response. Co-located with the Request so the full "Insert User" wire
// surface (input shape + output shape + both boundaries) lives in one file.
func (InsertUserResponse) FromResult(r commands.InsertUserResult) InsertUserResponse {
	return InsertUserResponse{
		ID:                r.ID,
		Name:              r.Name,
		Email:             r.Email,
		Phone:             r.Phone,
		Document:          r.Document,
		UserName:          r.UserName,
		EmailNotification: r.EmailNotification,
		SmsNotification:   r.SmsNotification,
	}
}
