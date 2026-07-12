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
// the persisted entity's identity + root field snapshot + the FULL aggregate
// mirror (the current addresses, with the ids the persister minted) — the
// framework dispatches via responseProjection (this struct's FromResult) and
// wraps the envelope around it.
type InsertUserResponse struct {
	ID                domain.ID                   `json:"id"                          example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name              string                      `json:"name"                        example:"Alice Pereira"`
	Email             string                      `json:"email"                       example:"alice@example.com"`
	Phone             *string                     `json:"phone,omitempty"             example:"14155552671"`
	Document          string                      `json:"document"                    example:"12345678901"`
	UserName          string                      `json:"userName"                    example:"alice"`
	EmailNotification *bool                       `json:"emailNotification,omitempty" example:"true"`
	SmsNotification   *bool                       `json:"smsNotification,omitempty"   example:"false"`
	Addresses         []InsertUserResponseAddress `json:"addresses"`
}

// InsertUserResponseAddress is the wire shape of one mirrored address row —
// same field set as AddressRequest on the way in, with the persisted id on
// the way out. Reused by UpdateUserResponse (the PUT mirrors the replaced
// collection the same way).
type InsertUserResponseAddress struct {
	ID           string  `json:"id"                   example:"d8e6f4a2-1a3b-4c5d-9e7f-8a9b0c1d2e3f"`
	Label        *string `json:"label,omitempty"      example:"home"`
	Street       string  `json:"street"               example:"1 Infinite Loop"`
	Number       string  `json:"number"               example:"1"`
	Complement   *string `json:"complement,omitempty" example:"Apt 4B"`
	Neighborhood string  `json:"neighborhood"         example:"Mariani"`
	City         string  `json:"city"                 example:"Cupertino"`
	State        string  `json:"state"                example:"CA"`
	ZipCode      string  `json:"zipCode"              example:"95014"`
	Country      string  `json:"country"              example:"US"`
}

// insertUserResponseAddresses maps the Result's address snapshots to the wire
// rows. Shared with UpdateUserResponse.FromResult.
func insertUserResponseAddresses(in []commands.AddressResult) []InsertUserResponseAddress {
	out := make([]InsertUserResponseAddress, 0, len(in))
	for _, a := range in {
		out = append(out, InsertUserResponseAddress{
			ID:           a.ID,
			Label:        a.Label,
			Street:       a.Street,
			Number:       a.Number,
			Complement:   a.Complement,
			Neighborhood: a.Neighborhood,
			City:         a.City,
			State:        a.State,
			ZipCode:      a.ZipCode,
			Country:      a.Country,
		})
	}
	return out
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
		Addresses:         insertUserResponseAddresses(r.Addresses),
	}
}
