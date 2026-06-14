package requests

import (
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	"github.com/ClaudioSchirmer/omnicore-example-users/application/dtos"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// UpdateUserRequest is the wire shape of PUT /users/:id (full replace, strict
// body — UpdateCommandHandler embeds FullBody in the framework). Shape
// mirrors UpdateUserCommand 1:1. All exported fields are mandatory — a field
// missing from the JSON fires 400 with RequiredFieldNotification per field
// (semantic Schema), via HandleCommandWithBodyID + FullBody marker.
type UpdateUserRequest struct {
	Name      string           `json:"name"            example:"Alice Pereira"`
	Email     string           `json:"email"           example:"alice@example.com"`
	Phone     *string          `json:"phone,omitempty" example:"14155552671"`
	Addresses []AddressRequest `json:"addresses"`
}

// ToCommand converts the Request DTO into the Command. Boundary
// web→application: pure body assignment. AppContext is NOT received — the
// application layer (Command.ApplyTo) is where ctx interpretation happens.
func (r UpdateUserRequest) ToCommand() *commands.UpdateUserCommand {
	addrs := make([]dtos.AddressInput, len(r.Addresses))
	for i, a := range r.Addresses {
		addrs[i] = a.ToAddressInput()
	}
	return &commands.UpdateUserCommand{
		Name:      r.Name,
		Email:     r.Email,
		Phone:     r.Phone,
		Addresses: addrs,
	}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// UpdateUserResponse is the wire shape of PUT /users/:id on success. Carries
// the post-update root snapshot.
type UpdateUserResponse struct {
	ID    domain.ID `json:"id"              example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name  string    `json:"name"            example:"Alice Pereira"`
	Email string    `json:"email"           example:"alice@example.com"`
	Phone *string   `json:"phone,omitempty" example:"14155552671"`
}

func (UpdateUserResponse) FromResult(r commands.UpdateUserResult) UpdateUserResponse {
	return UpdateUserResponse{
		ID:    r.ID,
		Name:  r.Name,
		Email: r.Email,
		Phone: r.Phone,
	}
}
