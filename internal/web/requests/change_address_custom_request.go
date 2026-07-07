package requests

import (
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
)

// ChangeAddressCustomRequest is the wire shape of PUT
// /showcase/users-custom/:document/addresses/:addressId. Two `path:` tags
// (Document + AddressID) keep the route's identifiers tagged on the DTO so
// a reverse-engineering pass introspects them via reflection without
// grepping handler bodies — same convention every other manual showcase
// route follows.
//
// Body shape mirrors AddressCustomRequest (no `Document` field — Document is
// the immutable surface key on this route). The manual route does NOT
// enforce the FullBody strict-body check the canonical PUT applies; the
// hand-rolled handler accepts whatever the consumer sent and lets
// BuildRules reject missing required fields with 422.
type ChangeAddressCustomRequest struct {
	Document     string  `path:"document"`
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

// ToCommand converts the Request DTO into the Command. DocumentKey + AddressID
// come from req's path-tagged fields populated by fwweb.BindPath; the
// address body fields go through dtos.AddressInputCustom — the same
// application DTO Insert/Update Custom consume.
func (r ChangeAddressCustomRequest) ToCommand() *commands.ChangeAddressCustomCommand {
	return &commands.ChangeAddressCustomCommand{
		DocumentKey: r.Document,
		AddressID:   r.AddressID,
		Address: dtos.AddressInputCustom{
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
