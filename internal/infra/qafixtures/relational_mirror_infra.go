//go:build qa

// This file declares the RELATIONAL-SOURCE mirror views: read-side twins of the
// flat, normal (no embed/link, no SharedBase/Composed) qa views, each marked with
// .RelationalSource(loader) so its reads come straight from the relational SoR
// through an AggregateLoader instead of the Mongo projection. They project the
// SAME root tables and reuse the SAME TableSchemas as their Mongo originals, so
// the four web surfaces read a byte-equivalent document either way — the parity
// the `relational_view` QA suite asserts. Present only in the `qa` build.
package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/read"
	fwdb "github.com/ClaudioSchirmer/omnicore/infra/db/core"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// GadgetRelView is the RelationalSource twin of GadgetView over the SAME `gadgets`
// root. Its loader is a fresh AggregateLoader bound to GadgetSchema — the boot
// guard verifies that binding matches the view's schema table. No Mongo Indexes:
// a relational view materializes no collection (the SyncEngine and the Mongo spec
// pass both skip it), so the SoR's own indexes serve every read.
func GadgetRelView(eng fwdb.RelationalEngine) *query.ViewDefinition {
	loader := read.NewAggregateLoader[*qadomain.Gadget](
		eng, func() *qadomain.Gadget { return &qadomain.Gadget{} },
	).WithSchema(GadgetSchema())
	return query.View("gadgets_rel").
		Version(1).
		Schema(GadgetSchema()).
		RelationalSource(loader)
}

// GadgetCappedRelView is a SECOND relational twin over the same `gadgets` root,
// carrying a small per-view MaxLimit(5) AND MaxExportRows(3). It proves the
// relational reader honors BOTH read-side ceilings exactly like the Mongo reader:
// a `?limit=` over 5 is rejected 400 LimitExceededNotification, and a CSV/XLSX
// export truncates to 3 rows (the export path's own ceiling, applied ahead of the
// reader and served through BypassMaxLimit).
func GadgetCappedRelView(eng fwdb.RelationalEngine) *query.ViewDefinition {
	loader := read.NewAggregateLoader[*qadomain.Gadget](
		eng, func() *qadomain.Gadget { return &qadomain.Gadget{} },
	).WithSchema(GadgetSchema())
	return query.View("gadgets_capped_rel").
		Version(1).
		Schema(GadgetSchema()).
		MaxLimit(5).
		MaxExportRows(3).
		RelationalSource(loader)
}

// LensBrandsRelView is the RelationalSource twin of LensBrandsView over the flat
// `qa_lens_brands` root — a second view family (different schema/DTO) proving the
// mirror is not gadget-specific.
func LensBrandsRelView(eng fwdb.RelationalEngine) *query.ViewDefinition {
	loader := read.NewAggregateLoader[*qadomain.LensBrand](
		eng, func() *qadomain.LensBrand { return &qadomain.LensBrand{} },
	).WithSchema(LensBrandSchema())
	return query.View("qa_lens_brands_view_rel").
		Version(1).
		Schema(LensBrandSchema()).
		RelationalSource(loader)
}
