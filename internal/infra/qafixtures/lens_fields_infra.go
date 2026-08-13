//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
)

// The JoinView FIELDS family — three additional projections over the EXISTING
// lens roots (qa_lens_parts / qa_lens_kits), each declaring a Fields allowlist
// on its leg. A SIDE family on purpose: it adds views only (no new tables, no
// new write verbs, no change to any existing view), so every other suite is
// untouched — writes flow through the existing /qa/lens-* routes and these
// projections materialize beside the originals from the same events.
//
//	qa_lens_brands_view ──1:1 Fields("Name")────────────▶ qa_lens_fields_forever_view
//	qa_lens_brands_view ──1:1 Fields("Name","DeletedAt")─▶ qa_lens_fields_lifecycle_view
//	qa_lens_parts_view ───1:N Fields("Label","Slot","Brand")─▶ qa_lens_fields_kits_view
//
// The pair over the SAME source is the archive switch made observable: one
// event stream, two declared regimes.

// LensFieldsForeverLeg cuts the brand segment to the name alone — "DeletedAt"
// is NOT listed, so the segment has NO archived rule, by declaration: the
// archived brand keeps its name in every part document forever and keeps
// receiving renames through the ripple.
func LensFieldsForeverLeg() *query.Leg {
	return query.JoinView(LensBrandsView(), "Brand", "brand").
		Fields("Name")
}

// LensFieldsLifecycleLeg lists "DeletedAt" too — the segment follows the
// source's archive: hidden on default reads, revealed by ?includeArchived.
func LensFieldsLifecycleLeg() *query.Leg {
	return query.JoinView(LensBrandsView(), "Brand", "brand").
		Fields("Name", "DeletedAt")
}

// LensFieldsForeverView projects the SAME qa_lens_parts root as
// qa_lens_parts_view, with the brand segment capped to the name ("name forever").
func LensFieldsForeverView() *query.ViewDefinition {
	return query.View("qa_lens_fields_forever_view").
		Version(1).
		Schema(LensPartSchema()).
		Embed(LensFieldsForeverLeg()).On("brand_id").
		Indexes(
			query.Index("brand_id"), // the 1:1 ripple's reverse scan
			query.Index("label"),
		)
}

// LensFieldsLifecycleView is the same shape with the archive rule ON.
func LensFieldsLifecycleView() *query.ViewDefinition {
	return query.View("qa_lens_fields_lifecycle_view").
		Version(1).
		Schema(LensPartSchema()).
		Embed(LensFieldsLifecycleLeg()).On("brand_id").
		Indexes(
			query.Index("brand_id"),
			query.Index("label"),
		)
}

// LensFieldsKitsView exercises the 1:N + segment-admission shape: each kit
// materializes its parts capped to Label + Slot + the Brand segment ADMITTED
// WHOLE — the parts view's OTHER segment (Gadget) and its remaining root
// columns are cut. Slot doubles as the declared order (force-included) and
// kit_id is the leg-side join column (force-included); the covering index the
// per-parent lookup needs lives on the SOURCE view (qa_lens_parts_view already
// declares Index("kit_id")).
func LensFieldsKitsView() *query.ViewDefinition {
	return query.View("qa_lens_fields_kits_view").
		Version(1).
		Schema(LensKitSchema()).
		EmbedMany(query.JoinView(LensPartsView(), "Parts", "parts").
			Fields("Label", "Slot", "Brand")).
		OrderBy("slot").On("kit_id").
		Indexes(query.Index("name"))
}
