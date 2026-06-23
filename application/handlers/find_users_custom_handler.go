package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/queries"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
)

// FindUsersCustomQueryHandler powers the paged list under GET /showcase/users-custom.
// Returns the framework's queries.Page so the web layer can carry the
// cursor envelope into the wire response — same shape the canonical
// FindByParamsQueryHandler returns; the difference is the projection
// step happens in web/, not in the framework wrapper.
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
) (queries.Page, error) {
	criteria, err := q.ToCriteria(ctx)
	if err != nil {
		return queries.Page{}, err
	}
	if criteria.Filter == nil {
		criteria.Filter = map[string]any{}
	}

	// ─── Custom filter seam (mirror of FindUserByEmailCustomQueryHandler) ────────────
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
	//   // Force a default Sort so pagination cursors stay stable across
	//   // consumers that did not supply ?sort.
	//   if len(criteria.Sort) == 0 {
	//       criteria.Sort = []queries.SortField{{Field: "CreatedAt", Desc: true}}
	//   }
	//
	// Sort/pagination overlays belong on this seam — they shape the
	// response without leaking into the wire layer.
	//
	// ──────────────────────────────────────────────────────────────────────

	return h.Reader.ReadPage(ctx, h.View, criteria)
}
