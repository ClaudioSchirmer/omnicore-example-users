package dtos

import appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"

// AddressInput is the application-layer DTO shared between InsertUser and
// UpdateUser commands. Phase 21: no JSON tags (wire format lives in
// web/requests/AddressRequest) and types mirror AddressRequest 1:1 — optional
// fields carry *string on both sides so that ToCommand is a pure assignment
// with no hidden normalization at the boundary.
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
}

// ToAddress materializes an appdomain.Address from the AddressInput. Since
// AddressInput already speaks application vocabulary (pointer types for
// nullable), the mapping to domain is a direct copy — domain.Address also
// declares Label/Complement as *string.
func (a AddressInput) ToAddress() appdomain.Address {
	return appdomain.Address{
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
