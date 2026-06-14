package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/domain"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
)

// FindUserByEmailCustomQueryHandler resolves /showcase/users-custom/:email by issuing
// a single-item ReadPage with Filter[email]=<value>. The canonical
// FindByIDQueryHandler cannot be reused — it only knows the document's
// primary-key path via ViewReader.ReadByID; the by-email lookup needs an
// arbitrary filter, which is what ReadPage already supports.
//
// Returns the raw Mongo document (map[string]any) and lets the web layer
// project it into a wire-format response (FindUserByEmailCustomResponse,
// co-located with its Request in web/requests/).
// Keeping the projection on the web side preserves the canonical
// application → wire boundary — application speaks documents, web speaks
// JSON.
type FindUserByEmailCustomQueryHandler struct {
	Reader queries.ViewReader
	View   string
}

func (h *FindUserByEmailCustomQueryHandler) Handle(
	ctx *configuration.AppContext, q *appqueries.FindUserByEmailQuery,
) (map[string]any, error) {
	criteria := q.ToCriteria(ctx)
	if criteria.Filter == nil {
		criteria.Filter = map[string]any{}
	}

	// ─── Custom filter seam (the reason this manual handler exists) ───────
	//
	// The framework's Auto FindByIDQueryHandler doesn't expose a hook for
	// injecting filters; this manual handler is where row-level access
	// control belongs. Typical use cases — uncomment and adapt:
	//
	//   // Multi-tenant SaaS: scope every read to the requesting tenant.
	//   if tenant, _ := ctx.Identity().Claims["tenant_id"].(string); tenant != "" {
	//       criteria.Filter["tenant_id"] = tenant
	//   }
	//
	//   // Owner-only: a regular user only sees their own row.
	//   if sub := ctx.ActorSubject(); sub != "anonymous" && !isAdmin(ctx) {
	//       criteria.Filter["owner_id"] = sub
	//   }
	//
	//   // Business overlay: hide internal accounts from every public read.
	//   criteria.Filter["kind"] = map[string]any{"$ne": "internal"}
	//
	// If the access filter rejects the requested row, ReadPage returns 0
	// items and the handler emits the canonical 404 — same status the
	// canonical /users/:id surface produces for missing rows.
	//
	// ──────────────────────────────────────────────────────────────────────

	page, err := h.Reader.ReadPage(ctx, h.View, criteria)
	if err != nil {
		return nil, err
	}
	if len(page.Items) == 0 {
		return nil, domain.NotFoundError("User", "email", q.Email)
	}
	return page.Items[0], nil
}
