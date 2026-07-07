package requests

import (
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// FindAddressByDocumentAndIDRequest is the wire allowlist for GET
// /showcase/users-custom/:document/addresses/:addressId. Both identifiers
// arrive via `path:` tags; only `?includeArchived=true|false` is recognized
// as a query parameter — any other key produces the canonical 400 envelope
// via the fwweb.ParseCriteria allowlist check the route runs after BindPath.
type FindAddressByDocumentAndIDRequest struct {
	Document        string `path:"document"`
	AddressID       string `path:"addressId"`
	IncludeArchived *bool  `query:"includeArchived"`
}

// ToQuery is the web→application boundary — pure body mapping with no ctx.
// Reads the path values populated by BindPath and the validated criteria
// from ParseCriteria. AppContext-derived overlays (future JWT tenant id)
// layer onto the criteria inside Query.ToCriteria(ctx) consumed by the
// handler.
func (r FindAddressByDocumentAndIDRequest) ToQuery(criteria fwqueries.ReadCriteria) *queries.FindAddressByDocumentAndIDQuery {
	return &queries.FindAddressByDocumentAndIDQuery{
		Document:        r.Document,
		AddressID:       r.AddressID,
		IncludeArchived: criteria.IncludeArchived,
	}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FindAddressByDocumentAndIDResponse is the reduced wire projection of one
// address sub-document for the manual showcase. Mirrors the surface's
// identity — id + street + city + country, dropping the larger fields
// the canonical FindAddressByIDResponse exposes — to demonstrate that
// wire format and view format are independent concerns: the same view
// doc feeds multiple projections. Per-endpoint co-located with the
// Request following the same convention as the other manual reads.
//
// Non-sparse contract: plain `string` fields (no `*T` + ,omitempty). The
// endpoint does not declare `query:"fields"`, so the Response is free to
// render every field with its zero value — a missing key in the doc lands
// as `""` on the wire instead of being elided. Projection runs through
// fwresponses.AutoFromDoc[FindAddressByDocumentAndIDResponse] at the route;
// AutoFromDoc handles both sparse (*T+omitempty) and non-sparse (string)
// shapes uniformly.
type FindAddressByDocumentAndIDResponse struct {
	ID      string `json:"id"      example:"d8e6f4a2-1a3b-4c5d-9e7f-8a9b0c1d2e3f"`
	Street  string `json:"street"  example:"1 Infinite Loop"`
	City    string `json:"city"    example:"Cupertino"`
	Country string `json:"country" example:"US"`
}
