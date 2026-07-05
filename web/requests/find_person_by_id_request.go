package requests

import (
	"github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// FindPersonByIDRequest is the wire allowlist for GET /persons/:id. The only
// reserved query parameter is ?includeArchived=true; anything else produces
// 400 at the wrapper before this DTO is touched.
type FindPersonByIDRequest struct {
	IncludeArchived *bool `query:"includeArchived"`
}

func (r FindPersonByIDRequest) ToQuery() *queries.FindPersonByIDQuery {
	arch := false
	if r.IncludeArchived != nil {
		arch = *r.IncludeArchived
	}
	return &queries.FindPersonByIDQuery{IncludeArchived: arch}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FindPersonByIDResponse is the wire projection of the person document for
// GET /persons/:id — the same shape as one list item (the list DTO is reused
// per nested type). Role fields are pointers so an absent role (null segment)
// disappears from the wire.
type FindPersonByIDResponse struct {
	ID       string  `json:"id"                 example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name     string  `json:"name"               example:"Alice Pereira"`
	Email    string  `json:"email"              example:"alice@example.com"`
	Phone    *string `json:"phone,omitempty"    example:"14155552671"`
	Document string  `json:"document"           example:"12345678901"`

	Addresses []FindUserByIDAddressOutput `json:"addresses"`
	User      *PersonUserOutput           `json:"user,omitempty"`
	Employee  *PersonEmployeeOutput       `json:"employee,omitempty"`
}
