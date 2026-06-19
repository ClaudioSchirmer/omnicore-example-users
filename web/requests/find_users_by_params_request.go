package requests

import (
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// FindUsersByParamsRequest declares the wire allowlist for GET /users via
// struct tags consumed by fwweb.HandleQueryWithParams. Filterable fields
// carry a filter tag with the operators they accept; pagination/control
// keys carry only a query tag and are recognized by the framework's reserved
// set (limit/after/before/sort/fields/search/includeArchived).
//
// Nested embed groups mirror the Response side: a struct-typed field
// carrying a query:"prefix" tag (no filter:) is an embed group; each leaf
// inside contributes a wire key prefixed by its parent (so City below
// surfaces as ?addresses.city=Berlin). The wrapper maps the wire key to the
// Go field path (Addresses.City); the MongoViewReader then translates that
// Go path to the physical Mongo path (addresses.city) via the view's
// TableSchema — no PascalToSnake, no view: tag at this layer.
//
// The fields are tag carriers — the wrapper parses the query string directly
// into a ReadCriteria and hands it to ToQuery. AppContext-derived overlays
// (tenant id from a future JWT middleware) layer onto the criteria inside
// the Query's ToCriteria(ctx), consumed by the handler — ToQuery itself is
// pure body mapping, no ctx parameter.
type FindUsersByParamsRequest struct {
	Name      *string             `query:"name"  filter:"eq,startswith,icontains,istartswith"`
	Email     *string             `query:"email" filter:"eq,in,ieq"`
	Addresses AddressFilterParams `query:"addresses"`

	Limit           *int64  `query:"limit"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	Sort            *string `query:"sort"`
	Fields          *string `query:"fields"`
	Search          *string `query:"search"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

// AddressFilterParams is the embed-group counterpart of the Address output
// — same vocabulary, filter side. Wire keys land prefixed by the parent
// field's query tag, so ?addresses.city=Berlin and ?addresses.zipCode=10001
// become Go field paths (Addresses.City / Addresses.ZipCode); the reader
// translates them to the physical Mongo paths (addresses.city /
// addresses.zip_code) via the view's TableSchema — no view: declaration.
type AddressFilterParams struct {
	City    *string `query:"city"    filter:"eq,istartswith,icontains"`
	State   *string `query:"state"   filter:"eq,in"`
	Country *string `query:"country" filter:"eq,in"`
	ZipCode *string `query:"zipCode" filter:"eq,startswith"`
}

func (r FindUsersByParamsRequest) ToQuery(criteria fwqueries.ReadCriteria) *queries.FindUserByParamsQuery {
	return &queries.FindUserByParamsQuery{Criteria: criteria}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FindUsersByParamsResponse is the wire projection of one User view document
// in the GET /users list. The route pairs it with
// fwresponses.AutoFromDoc[FindUsersByParamsResponse]; see
// FindUserByIDResponse for the json: tag contract.
//
// Every field — at every depth — is *T (or a slice) and carries ,omitempty
// because the Request DTO declares `?fields=` and the framework's boot
// guard enforces the sparse-render contract: when the consumer asks for a
// subset (`?fields=name,email`), Mongo strips the unwanted columns and
// encoding/json elides the absent values via the omitempty modifier.
// Without pointers + omitempty, a stripped `name` would still render as
// `"name":""` (zero value), defeating the point of the parameter.
type FindUsersByParamsResponse struct {
	ID        *string                          `json:"id,omitempty"        example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name      *string                          `json:"name,omitempty"      example:"Alice Pereira"`
	Email     *string                          `json:"email,omitempty"     example:"alice@example.com"`
	Phone     *string                          `json:"phone,omitempty"     example:"14155552671"`
	Addresses []FindUsersByParamsAddressOutput `json:"addresses,omitempty"`
}

// FindUsersByParamsAddressOutput is the nested wire shape of one Address
// inside a list item. Same pointer + omitempty rule applies recursively:
// nested filters like `?fields=addresses.city` only populate City, and
// every other field of the Address subdoc renders absent rather than as
// the empty string. The MongoViewReader already translated each physical
// column back to its Go field name via the view's AddressSchema (zip_code →
// ZipCode), so AutoFromDoc keys by the Go field name and the json: tag is
// only the outgoing wire name — no view: source-key override.
type FindUsersByParamsAddressOutput struct {
	ID           *string `json:"id,omitempty"           example:"d8e6f4a2-1a3b-4c5d-9e7f-8a9b0c1d2e3f"`
	Label        *string `json:"label,omitempty"        example:"home"`
	Street       *string `json:"street,omitempty"       example:"1 Infinite Loop"`
	Number       *string `json:"number,omitempty"       example:"1"`
	Complement   *string `json:"complement,omitempty"   example:"Apt 4B"`
	Neighborhood *string `json:"neighborhood,omitempty" example:"Mariani"`
	City         *string `json:"city,omitempty"         example:"Cupertino"`
	State        *string `json:"state,omitempty"        example:"CA"`
	ZipCode      *string `json:"zipCode,omitempty"      example:"95014"`
	Country      *string `json:"country,omitempty"      example:"US"`
}
