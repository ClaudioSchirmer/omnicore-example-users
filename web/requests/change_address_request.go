package requests

import (
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	"github.com/ClaudioSchirmer/omnicore-example-users/application/dtos"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// ChangeAddressRequest is the wire shape of PUT
// /users/:id/addresses/:addressId (full replace of one address, strict body —
// UpdateCommandHandler embeds FullBody in the framework). The User UUID
// arrives via the wrapper's `:id` auto-bind (no `path:"id"` here — boot
// would panic on the duplicate); the address UUID arrives via the
// `path:"addressId"` tag.
//
// The body matches the AddressRequest shape used by Insert/Update — all
// address fields are mandatory and FullBody enforces them at the wire
// before Dispatch. The framework treats `path:`-tagged fields as wire-side
// path parameters, so AddressID does NOT count against FullBody's required-
// set on the body.
type ChangeAddressRequest struct {
	AddressID    string  `path:"addressId"`
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

// ToCommand converts the Request DTO into the Command. Boundary
// web→application: pure body assignment. AppContext is NOT received — the
// application layer (Command.ApplyTo) is where ctx interpretation happens.
// The wrapper assigns cmd.SetPathID(userUUID) AFTER ToCommand returns, so
// the User UUID is filled by the framework — not by this method.
func (r ChangeAddressRequest) ToCommand() *commands.ChangeAddressCommand {
	return &commands.ChangeAddressCommand{
		AddressID: r.AddressID,
		Address: dtos.AddressInput{
			Label:        r.Label,
			Street:       r.Street,
			Number:       r.Number,
			Complement:   r.Complement,
			Neighborhood: r.Neighborhood,
			City:         r.City,
			State:        r.State,
			ZipCode:      r.ZipCode,
			Country:      r.Country,
		},
	}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// ChangeAddressResponse is the wire shape of PUT
// /users/:id/addresses/:addressId on success. Carries the post-update
// state of the address that was changed, plus the parent user's ID for
// link-back. The address shape mirrors the canonical Address shape used
// in Insert/Update/Get.
type ChangeAddressResponse struct {
	UserID  domain.ID                    `json:"userId"  example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Address ChangeAddressResponseAddress `json:"address"`
}

// ChangeAddressResponseAddress is the wire shape of the mutated address row.
// Same field set as AddressRequest on the way in, with id+JSON tags on the
// way out.
type ChangeAddressResponseAddress struct {
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

// FromResult is the application Result → wire Response mapper. Pure
// field-by-field assignment.
func (ChangeAddressResponse) FromResult(r commands.ChangeAddressResult) ChangeAddressResponse {
	return ChangeAddressResponse{
		UserID: r.UserID,
		Address: ChangeAddressResponseAddress{
			ID:           r.Address.ID,
			Label:        r.Address.Label,
			Street:       r.Address.Street,
			Number:       r.Address.Number,
			Complement:   r.Address.Complement,
			Neighborhood: r.Address.Neighborhood,
			City:         r.Address.City,
			State:        r.Address.State,
			ZipCode:      r.Address.ZipCode,
			Country:      r.Address.Country,
		},
	}
}
