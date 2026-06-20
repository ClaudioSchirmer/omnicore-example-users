package handlers

import (
	"reflect"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/domain"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
)

// FindAddressByIDQueryHandler resolves GET /users/:id/addresses/:addressId
// against the users Mongo view. The framework's Auto FindByIDQueryHandler
// returns the whole user document; here we go one step further: load the
// document, walk its `addresses` array, and return only the entry whose ID
// matches the requested addressId. Returns the raw address sub-document
// (map[string]any) and lets the web layer project it into a wire-format
// response — same convention the manual showcase by-email handler follows.
//
// Why a hand-rolled handler on the "canonical" surface: the framework does
// not ship a generic "child of view doc" query handler. The two coexisting
// patterns are FindByID (full root doc) and FindByParams (paged list). A
// child read sits in between — load the parent, project one item. Keeping
// the surface canonical while writing the projection logic by hand is the
// honest middle ground; the framework absorbs the lookup primitive
// (ViewReader.ReadByID), the consumer absorbs the per-child slice walk.
type FindAddressByIDQueryHandler struct {
	Reader queries.ViewReader
	View   string
}

func (h *FindAddressByIDQueryHandler) Handle(
	ctx *configuration.AppContext, q *appqueries.FindAddressByIDQuery,
) (map[string]any, error) {
	criteria := q.ToCriteria(ctx)

	// ─── Custom filter seam (same as the manual showcase by-email read) ────
	//
	// The reader's ReadByID merges criteria.Filter into the {_id: id} +
	// deleted_at gate. Filter keys are Go field names declared in the
	// TableSchema (the reader translates them to physical columns). Use the
	// seam for row-level access control:
	//
	//   if tenant, _ := ctx.Identity().Claims["tenant_id"].(string); tenant != "" {
	//       if criteria.Filter == nil { criteria.Filter = map[string]any{} }
	//       criteria.Filter["TenantID"] = tenant
	//   }
	//
	// When the access filter rejects the requested user, ReadByID returns
	// found=false and the handler emits the canonical 404 — same status the
	// missing-user case produces.
	//
	// ──────────────────────────────────────────────────────────────────────

	userID := q.GetID().Value()
	doc, found, err := h.Reader.ReadByID(ctx, h.View, userID, criteria)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, domain.NotFoundError("User", "id", userID)
	}

	if addr, ok := pickAddressByID(doc["Addresses"], q.AddressID); ok {
		return addr, nil
	}
	return nil, domain.NotFoundError("Address", "id", q.AddressID)
}

// pickAddressByID walks any slice-like value (plain []any, []map[string]any,
// or mongo-driver's named bson.A) carrying map-like elements and returns
// the entry whose "ID" field equals addressID. The MongoViewReader returns a
// Go-keyed document (each embed leaf translated from its physical column back
// to its Go field name via the view's TableSchema), so the lookup keys on the
// Go field name "ID", not the physical column "id". Uses reflection so the
// application layer stays free of bson imports — the framework's
// AutoFromDoc projector uses the same trick (asSliceOfMaps in
// omnicore/web/responses/auto_from_doc.go) for the same reason.
func pickAddressByID(v any, addressID string) (map[string]any, bool) {
	rv := reflect.ValueOf(v)
	if !rv.IsValid() || rv.Kind() != reflect.Slice {
		return nil, false
	}
	for i := 0; i < rv.Len(); i++ {
		item := rv.Index(i).Interface()
		addr, ok := item.(map[string]any)
		if !ok {
			// Mongo's bson.M decodes inner objects as a named map type
			// too; fall through reflection on the element if needed.
			rvi := reflect.ValueOf(item)
			if rvi.Kind() != reflect.Map {
				continue
			}
			addr = make(map[string]any, rvi.Len())
			iter := rvi.MapRange()
			for iter.Next() {
				addr[iter.Key().String()] = iter.Value().Interface()
			}
		}
		if id, _ := addr["ID"].(string); id == addressID {
			return addr, true
		}
	}
	return nil, false
}
