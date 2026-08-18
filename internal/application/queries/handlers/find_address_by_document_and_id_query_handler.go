package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/domain"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
)

// FindAddressByDocumentAndIDQueryHandler is the manual showcase twin of
// FindAddressByIDQueryHandler. Same projection — one address sub-document —
// reached via the document-keyed lookup the manual showcase uses on the read
// side. ReadPage with Filter[Document]+Limit:1, walks the embedded addresses[],
// returns the matching entry or a canonical 404 — User context when the
// parent is absent, Address context when the parent is present but the
// address id is not in the embedded array. Returns the TYPED Result: the raw
// document never leaves the application layer.
type FindAddressByDocumentAndIDQueryHandler struct {
	Reader queries.ViewReader
	View   string
}

func (h *FindAddressByDocumentAndIDQueryHandler) Handle(
	ctx *configuration.AppContext, q *appqueries.FindAddressByDocumentAndIDQuery,
) (appqueries.AddressResult, error) {
	var zero appqueries.AddressResult
	criteria, err := q.ToCriteria(ctx)
	if err != nil {
		return zero, err
	}
	if criteria.Filter == nil {
		criteria.Filter = map[string]any{}
	}

	// ─── Custom filter seam — same shape as find_user_by_email_custom ─────
	//
	// Filter keys are Go field names declared in the TableSchema; the reader
	// translates them to physical columns.
	//
	//   if tenant, _ := ctx.Identity().Claims["tenant_id"].(string); tenant != "" {
	//       criteria.Filter["TenantID"] = tenant
	//   }
	//
	// ──────────────────────────────────────────────────────────────────────

	page, err := h.Reader.ReadPage(ctx, h.View, criteria)
	if err != nil {
		return zero, err
	}
	if len(page.Items) == 0 {
		return zero, domain.NotFoundError("User", "document", q.Document)
	}
	doc := page.Items[0]

	if addr, ok := pickAddressByID(doc["Addresses"], q.AddressID); ok {
		return q.FromQueryResult(ctx, queries.ResultFromDoc[appqueries.AddressResult](addr))
	}
	return zero, domain.NotFoundError("Address", "id", q.AddressID)
}
