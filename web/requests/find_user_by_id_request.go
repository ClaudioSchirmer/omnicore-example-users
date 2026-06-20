package requests

import (
	"github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// FindUserByIDRequest is the wire allowlist for GET /users/:id. The only
// reserved query parameter is ?includeArchived=true; anything else produces
// 400 at the wrapper before this DTO is touched.
type FindUserByIDRequest struct {
	IncludeArchived *bool `query:"includeArchived"`
}

// ToQuery is the web→application boundary — pure body mapping with no ctx.
// AppContext flows into the application layer via Query.ToCriteria(ctx),
// where identity-derived overlays (tenant id, owner id) layer onto the
// criteria. Symmetric to InsertUserRequest.ToCommand on the write side.
func (r FindUserByIDRequest) ToQuery() *queries.FindUserByIDQuery {
	arch := false
	if r.IncludeArchived != nil {
		arch = *r.IncludeArchived
	}
	return &queries.FindUserByIDQuery{IncludeArchived: arch}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FindUserByIDResponse is the wire projection of the User view document for
// GET /users/:id. The route pairs it with fwresponses.AutoFromDoc[
// FindUserByIDResponse], so the projection is tag-driven and the per-Response
// FromDoc boilerplate is gone. The MongoViewReader already translates every
// physical column back to its Go field name using UserSchema()/AddressSchema()
// (mail → Email, zip_code → ZipCode, the embed doc field "addresses" → the Go
// segment "Addresses"), so AutoFromDoc keys by the Go field name and the only
// tag that governs the mapping is json:"<wire>" — the outgoing JSON name. No
// view: source-key override is needed; the three-name model (json ↔ Go ↔
// column) is resolved at the two membranes (web json↔Go, infra Go↔column).
//
// Co-location convention: Response and Request live in the same file; the
// nested address shape stays per-endpoint to keep the by-id and list
// surfaces independent if either evolves.
type FindUserByIDResponse struct {
	ID        string                      `json:"id"              example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name      string                      `json:"name"            example:"Alice Pereira"`
	Email     string                      `json:"email"           example:"alice@example.com"`
	Phone     *string                     `json:"phone,omitempty" example:"14155552671"`
	Addresses []FindUserByIDAddressOutput `json:"addresses"`
}

// FindUserByIDAddressOutput is the nested wire shape of one Address inside
// the by-id response. The reader translates each physical column back to its
// Go field name via AddressSchema (zip_code → ZipCode) before projection, so
// AutoFromDoc keys by the Go field name and the json: tag is only the outgoing
// wire name — no view: source-key override.
type FindUserByIDAddressOutput struct {
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
