package dtos

import appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"

// AddressInputCustom is the application-layer DTO used by the manual
// showcase commands (InsertUserCustomCommand / UpdateUserCustomCommand)
// under /showcase/users-custom/*. Same shape as AddressInput — the
// dedicated symbol exists so the canonical and manual surfaces share
// nothing above domain/, mirroring the *CustomCommand twin pattern.
//
// No JSON tags (wire format lives in web/requests/AddressCustomRequest);
// types mirror the wire DTO 1:1 — optional fields as *string on both sides
// so ToCommand is a pure assignment with no hidden normalization.
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
}

// ToAddress materializes an appdomain.Address from the DTO. Same direct
// copy as AddressInput.ToAddress — domain.Address is the single type
// reused across surfaces (only domain/ is shared between canonical and
// manual showcases).
func (a AddressInputCustom) ToAddress() appdomain.Address {
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
