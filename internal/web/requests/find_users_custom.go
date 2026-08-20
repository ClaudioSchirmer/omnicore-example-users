package requests

import (
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// FindUsersCustomRequest declares the wire allowlist for GET
// /showcase/users-custom via the same struct-tag convention the canonical
// /users surface uses. Filterable fields carry `query:"X" filter:"ops"`;
// pagination/control keys carry only `query:"X"`. The manual route runs a
// typed fwweb.QueryParser over this DTO to apply the same reflection-based
// validation QueryWithParams uses internally — an unknown key is a 400
// instead of being silently ignored, so the manual surface carries the same
// contract as the canonical one.
type FindUsersCustomRequest struct {
	Name  *string `query:"name"  filter:"eq" sort:"asc,desc"`
	Email *string `query:"email" filter:"eq" sort:"asc,desc"`

	First           *int64  `query:"first"`
	Last            *int64  `query:"last"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	IncludeArchived *bool   `query:"includeArchived"`
	Fields          *string `query:"fields"`
	Search          *string `query:"search"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

// ToQuery is the web→application boundary — pure body mapping with no ctx.
// AppContext-derived overlays (tenant scope, owner-only filter) layer onto
// the criteria inside Query.ToCriteria(ctx) consumed by the handler — the
// manual surface's reason to exist on the read side. The seam is
// documented in find_users_custom_query_handler.go.
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
// FromResult below delegates to the generic name-based mapper — the same
// seat the canonical /users surface uses. Read-side COMPUTATION (derived
// fields, ctx-aware shaping) belongs in the Query's FromQueryResult hook, not
// here, so every surface sees the same values.
type FindUsersCustomResponse struct {
	fwresponses.Auto

	ID    *string `json:"id,omitempty"    example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name  *string `json:"name,omitempty"  example:"Alice Pereira"`
	Email *string `json:"email,omitempty" example:"alice@example.com"`
}

// FromResult is the wire mapping seat, delegating to the generic name-based
// mapper.
func (FindUsersCustomResponse) FromResult(r queries.FindUsersCustomResult) FindUsersCustomResponse {
	return fwresponses.AutoFromResult[FindUsersCustomResponse](r)
}
