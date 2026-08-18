package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/domain"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
)

// FindUserByDocumentCustomQueryHandler resolves /showcase/users-custom/:document by
// issuing a single-item ReadPage with Filter[Document]=<value>. The canonical
// FindByIDQueryHandler cannot be reused — it only knows the row's primary-key
// path via ViewReader.ReadByID; the by-document lookup needs an arbitrary
// filter, which is what ReadPage already supports.
//
// Returns the TYPED Result the Query declares (the framework's
// queries.ResultFromDoc fills it from the canonical document, then the
// Query's FromQueryResult hook runs). The web layer maps that Result to its wire
// Response — application speaks Results, web speaks JSON, and the raw
// document never crosses the boundary.
type FindUserByDocumentCustomQueryHandler struct {
	Reader queries.ViewReader
	View   string
}

func (h *FindUserByDocumentCustomQueryHandler) Handle(
	ctx *configuration.AppContext, q *appqueries.FindUserByDocumentQuery,
) (appqueries.FindUserByDocumentResult, error) {
	var zero appqueries.FindUserByDocumentResult
	criteria, err := q.ToCriteria(ctx)
	if err != nil {
		return zero, err
	}
	if criteria.Filter == nil {
		criteria.Filter = map[string]any{}
	}

	// ─── Custom filter seam (the reason this manual handler exists) ───────
	//
	// The framework's Auto FindByIDQueryHandler doesn't expose a hook for
	// injecting filters; this manual handler is where row-level access
	// control belongs. Filter keys are the Go field names declared in the
	// entity's TableSchema (e.g. "Email"); the MongoViewReader translates
	// each to its physical column via the view schema, so a column rename is
	// transparent here. Typical use cases — uncomment and adapt (each key
	// below assumes a matching Field(...) on the schema):
	//
	//   // Multi-tenant SaaS: scope every read to the requesting tenant.
	//   if tenant, _ := ctx.Identity().Claims["tenant_id"].(string); tenant != "" {
	//       criteria.Filter["TenantID"] = tenant
	//   }
	//
	//   // Owner-only: a regular user only sees their own row.
	//   if sub := ctx.ActorSubject(); sub != "anonymous" && !isAdmin(ctx) {
	//       criteria.Filter["OwnerID"] = sub
	//   }
	//
	//   // Business overlay: hide internal accounts from every public read.
	//   criteria.Filter["Kind"] = map[string]any{"$ne": "internal"}
	//
	// If the access filter rejects the requested row, ReadPage returns 0
	// items and the handler emits the canonical 404 — same status the
	// canonical /users/:id surface produces for missing rows.
	//
	// ──────────────────────────────────────────────────────────────────────

	page, err := h.Reader.ReadPage(ctx, h.View, criteria)
	if err != nil {
		return zero, err
	}
	if len(page.Items) == 0 {
		return zero, domain.NotFoundError("User", "document", q.Document)
	}
	return q.FromQueryResult(ctx, queries.ResultFromDoc[appqueries.FindUserByDocumentResult](page.Items[0]))
}
