package dtos

import (
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/aggregatevos"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/vos"
)

// AddressInput is the application-layer DTO shared between InsertUser and
// UpdateUser commands. No JSON tags (wire format lives in
// web/requests/AddressRequest); the wire fields carry the value objects'
// underlying scalars (string for ZipCode, string token for AddressType) —
// ToAddress converts them to the value-object types.
type AddressInput struct {
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

// ToAddress materializes an aggregatevos.Address from the AddressInput. ZipCode
// and AddressType are value objects — a plain conversion, since the wire value
// is already the underlying scalar.
func (a AddressInput) ToAddress() aggregatevos.Address {
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
