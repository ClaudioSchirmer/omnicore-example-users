package requests

import (
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// FindUsersCustomRequest declares the wire allowlist for GET
// /showcase/users-custom via the same struct-tag convention the canonical
// /users surface uses. Filterable fields carry `query:"X" filter:"ops"`;
// pagination/control keys carry only `query:"X"`. The manual route invokes
// fwweb.ParseCriteria over this DTO to apply the same reflection-based
// validation QueryWithParams uses internally — chaves desconhecidas
// viram 400 instead of being silently ignored, closing the asymmetry the
// previous hand-parsed implementation carried.
type FindUsersCustomRequest struct {
	Name  *string `query:"name"  filter:"eq"`
	Email *string `query:"email" filter:"eq"`

	Limit           *int64  `query:"limit"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	IncludeArchived *bool   `query:"includeArchived"`
	Sort            *string `query:"sort"`
	Fields          *string `query:"fields"`
	Search          *string `query:"search"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

// ToQuery is the web→application boundary — pure body mapping with no ctx.
// AppContext-derived overlays (tenant scope, owner-only filter) layer onto
// the criteria inside Query.ToCriteria(ctx) consumed by the handler — the
// manual surface's reason to exist on the read side. The seam is
// documented in find_users_custom_handler.go.
func (r FindUsersCustomRequest) ToQuery(criteria fwqueries.ReadCriteria) *queries.FindUsersCustomQuery {
	return &queries.FindUsersCustomQuery{Criteria: criteria}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FindUsersCustomResponse is the reduced wire projection of one User view
// document in the manual showcase list. Mirrors FindUserByDocumentCustomResponse
// (id + name + email) and is intentionally a distinct Go type — per-endpoint
// co-location keeps each surface's wire contract independently evolvable.
//
// Every field is *string + ,omitempty because the Request DTO opts into
// `?fields=` — the framework's QueryParser boot guard enforces the sparse-
// render contract on this type (every exported field at every depth must be
// a pointer or slice with omitempty so encoding/json can elide stripped
// columns instead of rendering their zero value).
//
// Projection runs through fwresponses.AutoFromDoc[FindUsersCustomResponse]
// at the route — same tag-driven default the canonical /users surface uses.
// No FromDoc method is declared here: id/name/email with auto _id-fallback
// is mechanical extraction the framework already gives for free. Declare
// FromDoc only when the projection needs logic AutoFromDoc cannot express
// (derived fields, conditional shaping, ctx-aware projection).
type FindUsersCustomResponse struct {
	ID    *string `json:"id,omitempty"    example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name  *string `json:"name,omitempty"  example:"Alice Pereira"`
	Email *string `json:"email,omitempty" example:"alice@example.com"`
}
