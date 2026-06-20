package requests

import (
	"github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// FindAddressByIDRequest is the wire allowlist for the canonical
// GET /users/:id/addresses/:addressId. The User UUID is auto-bound by the
// HandleQueryWithID wrapper into the Query's embedded QueryBaseWithID via
// SetPathID — declaring `path:"id"` here would be a boot panic (the
// framework's auto-bind owns the `:id` slot). The Address UUID arrives via
// the `path:"addressId"` tag (BindPath populates it before ToQuery).
//
// Only `?includeArchived=true|false` is recognized as a query parameter; any
// other key produces the canonical 400 via the wrapper's allowlist.
type FindAddressByIDRequest struct {
	AddressID       string `path:"addressId"`
	IncludeArchived *bool  `query:"includeArchived"`
}

// ToQuery is the web→application boundary — pure body mapping with no ctx.
// Reads the Address UUID populated by BindPath and the `includeArchived` flag.
// The User UUID arrives later via QueryBaseWithID.SetPathID, invoked by
// the wrapper after ToQuery returns.
func (r FindAddressByIDRequest) ToQuery() *queries.FindAddressByIDQuery {
	arch := false
	if r.IncludeArchived != nil {
		arch = *r.IncludeArchived
	}
	return &queries.FindAddressByIDQuery{
		AddressID:       r.AddressID,
		IncludeArchived: arch,
	}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FindAddressByIDResponse is the wire projection of one address sub-document.
// Mirrors the shape of FindUserByIDAddressOutput. The MongoViewReader already
// translated every physical column back to its Go field name (zip_code →
// ZipCode) using AddressSchema(), so AutoFromDoc keys by the Go field name and
// the json tag is purely the outgoing wire name — no view: source-key override.
type FindAddressByIDResponse struct {
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
