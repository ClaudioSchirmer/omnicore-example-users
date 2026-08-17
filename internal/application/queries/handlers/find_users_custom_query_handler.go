package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/queries"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
)

// FindUsersCustomQueryHandler powers the paged list under GET /showcase/users-custom.
// Returns the framework's typed queries.PageOf so the web layer can carry the
// cursor envelope into the wire response — the SAME shape the canonical
// FindByParamsQueryHandler returns; the difference is only the wiring, never
// the contract (manual is an escape hatch for wiring control, not a poorer
// tier).
//
// The Fiber route is responsible for parsing the query string into
// Criteria (Limit, After, Before, archived, plus the demonstrated name +
// email filters). Sort/Projection/Search are left out by design — the
// manual surface picks the minimal set that exercises every layer; adding
// more filters is mechanical once the seam is in place.
type FindUsersCustomQueryHandler struct {
	Reader queries.ViewReader
	View   string
}

func (h *FindUsersCustomQueryHandler) Handle(
	ctx *configuration.AppContext, q *appqueries.FindUsersCustomQuery,
) (queries.PageOf[appqueries.FindUsersCustomResult], error) {
	criteria, err := q.ToCriteria(ctx)
	if err != nil {
		return queries.PageOf[appqueries.FindUsersCustomResult]{}, err
	}
	if criteria.Filter == nil {
		criteria.Filter = map[string]any{}
	}

	// ─── Custom filter seam (mirror of FindUserByDocumentCustomQueryHandler) ────────────
	//
	// Same row-level access-control seam as the by-email handler — for
	// lists the filter narrows the visible set, for by-key lookups it
	// gates a single document. Filter/Sort keys are Go field names declared
	// in the TableSchema (the reader translates them to physical columns).
	// Typical use cases — uncomment and adapt:
	//
	//   // Multi-tenant SaaS: scope every read to the requesting tenant.
	//   if tenant, _ := ctx.Identity().Claims["tenant_id"].(string); tenant != "" {
	//       criteria.Filter["TenantID"] = tenant
	//   }
	//
	//   // Cap Limit so a hostile caller cannot drain the collection.
	//   if criteria.Limit <= 0 || criteria.Limit > 100 {
	//       criteria.Limit = 50
	//   }
	//
	//   // Force a default OrderBy so pagination cursors stay stable across
	//   // consumers that did not supply ?orderBy.
	//   if len(criteria.OrderBy) == 0 {
	//       criteria.OrderBy = []queries.OrderByField{{Field: "CreatedAt", Desc: true}}
	//   }
	//
	// Sort/pagination overlays belong on this seam — they shape the
	// response without leaking into the wire layer.
	//
	// ──────────────────────────────────────────────────────────────────────

	page, err := h.Reader.ReadPage(ctx, h.View, criteria)
	if err != nil {
		return queries.PageOf[appqueries.FindUsersCustomResult]{}, err
	}
	// The same fill the Auto handler performs: one Result per document, each
	// passed through the Query's FromQueryResult hook.
	return queries.PageOfFrom(page, queries.FromQueryResultFiller[appqueries.FindUsersCustomResult](ctx, q))
}
