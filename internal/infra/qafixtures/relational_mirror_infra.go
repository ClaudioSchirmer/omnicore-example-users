//go:build qa

// This file declares the RELATIONAL-SOURCE mirror views: read-side twins of the
// flat, normal (no embed/link, no SharedBase/Composed) qa views, each marked with
// .RelationalSource(loader) so its reads come straight from the relational SoR
// through an AggregateLoader instead of the Mongo projection. They project the
// SAME root tables and reuse the SAME TableSchemas as their Mongo originals, so
// the four web surfaces read a byte-equivalent document either way — the parity
// the `relational_view` QA suite asserts.
//
// The loader is NOT built here: each twin RECEIVES the loader the feature already
// constructed for the aggregate's repository (repo.Loader, a query.RelationalReader
// bound to the same schema). One loader per aggregate, threaded into both the repo
// and the view — the "marker receives the repo's loader" design, no duplication.
// Present only in the `qa` build.
package qafixtures

import "github.com/ClaudioSchirmer/omnicore/infra/db/query"

// GadgetRelView is the RelationalSource twin of GadgetView over the SAME `gadgets`
// root, served through the gadget repository's loader. No Mongo Indexes: a
// relational view materializes no collection (the SyncEngine and the Mongo spec
// pass both skip it), so the SoR's own indexes serve every read.
func GadgetRelView(loader query.RelationalReader) *query.ViewDefinition {
	return query.View("gadgets_rel").
		Version(1).
		Schema(GadgetSchema()).
		RelationalSource(loader)
}

// GadgetCappedRelView is a SECOND relational twin over the same `gadgets` root
// (same loader), carrying a small per-view MaxLimit(5) AND MaxExportRows(3). It
// proves the relational reader honors BOTH read-side ceilings exactly like the
// Mongo reader: a `?first=` over 5 is rejected 400 LimitExceededNotification, and
// a CSV/XLSX export truncates to 3 rows.
func GadgetCappedRelView(loader query.RelationalReader) *query.ViewDefinition {
	return query.View("gadgets_capped_rel").
		Version(1).
		Schema(GadgetSchema()).
		MaxLimit(5).
		MaxExportRows(3).
		RelationalSource(loader)
}

// LensBrandsRelView is the RelationalSource twin of LensBrandsView over the flat
// `qa_lens_brands` root (the brand repository's loader) — a second view family
// proving the mirror is not gadget-specific.
func LensBrandsRelView(loader query.RelationalReader) *query.ViewDefinition {
	return query.View("qa_lens_brands_view_rel").
		Version(1).
		Schema(LensBrandSchema()).
		RelationalSource(loader)
}
