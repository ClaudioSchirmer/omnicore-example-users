package dtos

import (
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/aggregatevos"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/vos"
)

// AddressInputCustom is the application-layer DTO used by the manual
// showcase commands (InsertUserCustomCommand / UpdateUserCustomCommand)
// under /showcase/users-custom/*. Same shape as AddressInput — the
// dedicated symbol exists so the canonical and manual surfaces share
// nothing above domain/, mirroring the *CustomCommand twin pattern.
//
// No JSON tags (wire format lives in web/requests/AddressCustomRequest); the
// wire fields carry the value objects' underlying scalars — ToAddress converts.
type AddressInputCustom struct {
	Label        *string
	Street       string
	Number       string
	Complement   *string
	Neighborhood string
	City         string
	State        string
	ZipCode      string
	Country      string
	AddressType  string // enum token (string-backed)
}

// ToAddress materializes an aggregatevos.Address from the DTO. Same conversion
// as AddressInput.ToAddress — ZipCode and AddressType are value objects.
func (a AddressInputCustom) ToAddress() aggregatevos.Address {
	return aggregatevos.Address{
		Label:        a.Label,
		Street:       a.Street,
		Number:       a.Number,
		Complement:   a.Complement,
		Neighborhood: a.Neighborhood,
		City:         a.City,
		State:        a.State,
		ZipCode:      vos.ZipCode(a.ZipCode),
		Country:      a.Country,
		AddressType:  vos.AddressType(a.AddressType),
	}
}
