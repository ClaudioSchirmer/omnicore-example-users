package requests

import (
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// FindUserByDocumentCustomRequest is the wire allowlist for GET
// /showcase/users-custom/:document. Only ?includeArchived=true|false is
// recognized — the route uses fwweb.ParseCriteria over this DTO to reject
// every other query key with the canonical 400 envelope, matching what the
// auto HandleQueryByID wrapper enforces on /users/:id.
//
// Document carries `path:"document"`: the manual route chains fwweb.BindPath
// before fwweb.ParseCriteria so the framework reads c.Params("document")
// into req.Document automatically — same mechanism the canonical wrappers
// use internally. Document is the Person natural key, the stable handle this
// surface uses in place of the opaque id.
type FindUserByDocumentCustomRequest struct {
	Document        string `path:"document"`
	IncludeArchived *bool  `query:"includeArchived"`
}

// ToQuery is the web→application boundary — pure body mapping with no ctx.
// Reads req.Document (populated by BindPath from the URL segment) and the
// validated criteria from ParseCriteria; AppContext-derived overlays
// (future JWT tenant id, etc.) layer onto the criteria inside
// Query.ToCriteria(ctx), consumed by the handler. The Query then translates
// Document + IncludeArchived into a ReadCriteria with Filter[Document] +
// Limit:1 — the wire never knows how the lookup is shaped at the Mongo layer.
func (r FindUserByDocumentCustomRequest) ToQuery(criteria fwqueries.ReadCriteria) *queries.FindUserByDocumentQuery {
	return &queries.FindUserByDocumentQuery{
		Document:        r.Document,
		IncludeArchived: criteria.IncludeArchived,
	}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FindUserByDocumentCustomResponse is the reduced wire projection of one User
// view document for the manual showcase. Mirrors the surface's identity —
// id + name + email, dropping phone and addresses — so the read shape is
// stable per endpoint and consumers can branch UI on a guaranteed compact
// payload. Per-endpoint co-located with the Request following the same
// convention as the command-side input+output pair.
//
// Every field is *string + ,omitempty for symmetry with the list endpoint's
// twin shape (FindUsersCustomResponse) — keeps the wire contract uniform
// across the two reduced projections of this surface. The by-email DTO does
// not opt into `?fields=` today; the structural shape is preserved so a
// future opt-in is a one-line tag addition.
//
// Projection runs through fwresponses.AutoFromDoc[FindUserByDocumentCustomResponse]
// at the route — same tag-driven default the canonical /users surface uses.
// No FromDoc method is declared here: id/name/email with auto _id-fallback
// is mechanical extraction the framework already gives for free.
type FindUserByDocumentCustomResponse struct {
	ID       *string `json:"id,omitempty"       example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name     *string `json:"name,omitempty"     example:"Alice Pereira"`
	Email    *string `json:"email,omitempty"    example:"alice@example.com"`
	Document *string `json:"document,omitempty" example:"12345678901"`
}
