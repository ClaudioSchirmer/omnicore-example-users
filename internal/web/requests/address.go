package requests

import (
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
)

// AddressRequest is the wire shape of an Address inside Insert/Update
// payloads. Phase 21: shape mirrors dtos.AddressInput 1:1 (optionals as
// *string, mandatory as string) — ToAddressInput is a pure assignment with no
// boundary normalization. Optional field absent from JSON → nil; optional
// field present as "" → *"" (consumer sent it, domain decides whether to
// reject).
type AddressRequest struct {
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

// ToAddressInput converts the wire DTO into the application DTO. Boundary
// web→application: 1:1 assignment, zero normalization.
func (a AddressRequest) ToAddressInput() dtos.AddressInput {
	return dtos.AddressInput{
		Label:        a.Label,
		Street:       a.Street,
		Number:       a.Number,
		Complement:   a.Complement,
		Neighborhood: a.Neighborhood,
		City:         a.City,
		State:        a.State,
		ZipCode:      a.ZipCode,
		Country:      a.Country,
	}
}
