//go:build qa

package qafixtures

import (
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
)

// Wire DTOs for the MATERIALIZED view-on-view family. The decisive difference
// from the composed (read-time) surface is visible right here in the filters: a
// predicate on a segment field of a MATERIALIZED view SELECTS ROWS — the
// segment lives in the same document — whereas a composed leg filter only
// shapes what enters the segment. The suite asserts exactly that.

// ─── LensBrand writes + reads (the deepest hop) ──────────────────────────────

type InsertLensBrandRequest struct {
	Name string `json:"name" validate:"required" example:"Zeiss"`
}

func (r InsertLensBrandRequest) ToCommand() *appqa.InsertLensBrandCommand {
	return &appqa.InsertLensBrandCommand{Name: r.Name}
}

type UpdateLensBrandRequest struct {
	Name string `json:"name" validate:"required" example:"Zeiss Optics"`
}

func (r UpdateLensBrandRequest) ToCommand() *appqa.UpdateLensBrandCommand {
	return &appqa.UpdateLensBrandCommand{Name: r.Name}
}

type LensBrandWriteResponse struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func (LensBrandWriteResponse) FromResult(r appqa.LensBrandResult) LensBrandWriteResponse {
	return LensBrandWriteResponse{ID: r.ID.Value(), Name: r.Name}
}

type FindLensBrandsRequest struct {
	Name *string `query:"name" filter:"eq,contains"`

	Limit           *int64  `query:"limit"`
	After           *string `query:"after"`
	Sort            *string `query:"sort"`
	Fields          *string `query:"fields"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

func (r FindLensBrandsRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindLensBrandsQuery {
	return &appqa.FindLensBrandsQuery{Criteria: criteria}
}

type FindLensBrandsResponse struct {
	ID   *string `json:"id,omitempty"`
	Name *string `json:"name,omitempty"`
}

// ─── LensKit writes ──────────────────────────────────────────────────────────

type InsertLensKitRequest struct {
	Name string `json:"name" validate:"required" example:"Alpha kit"`
}

func (r InsertLensKitRequest) ToCommand() *appqa.InsertLensKitCommand {
	return &appqa.InsertLensKitCommand{Name: r.Name}
}

type UpdateLensKitRequest struct {
	Name string `json:"name" validate:"required" example:"Alpha kit v2"`
}

func (r UpdateLensKitRequest) ToCommand() *appqa.UpdateLensKitCommand {
	return &appqa.UpdateLensKitCommand{Name: r.Name}
}

type LensKitWriteResponse struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func (LensKitWriteResponse) FromResult(r appqa.LensKitResult) LensKitWriteResponse {
	return LensKitWriteResponse{ID: r.ID.Value(), Name: r.Name}
}

// ─── LensPart writes ─────────────────────────────────────────────────────────

type InsertLensPartRequest struct {
	KitID    *string `json:"kitId"    example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	GadgetID *string `json:"gadgetId" example:"2f1c9a80-1d2e-4b3c-8a7f-6e5d4c3b2a10"`
	BrandID  *string `json:"brandId"  example:"9a8b7c60-5d4e-4f3a-8b2c-1d0e9f8a7b60"`
	Label    string  `json:"label"    validate:"required" example:"left lens"`
	Slot     int     `json:"slot"     example:"1"`
}

func (r InsertLensPartRequest) ToCommand() *appqa.InsertLensPartCommand {
	return &appqa.InsertLensPartCommand{KitID: r.KitID, GadgetID: r.GadgetID, BrandID: r.BrandID, Label: r.Label, Slot: r.Slot}
}

// UpdateLensPartRequest carries BOTH foreign keys, so the suite can repoint a
// part at another gadget (the 1:1 segment must re-resolve) or move it to
// another kit (the element must leave one array and enter another).
type UpdateLensPartRequest struct {
	KitID    *string `json:"kitId"`
	GadgetID *string `json:"gadgetId"`
	BrandID  *string `json:"brandId"`
	Label    string  `json:"label" validate:"required"`
	Slot     int     `json:"slot"`
}

func (r UpdateLensPartRequest) ToCommand() *appqa.UpdateLensPartCommand {
	return &appqa.UpdateLensPartCommand{KitID: r.KitID, GadgetID: r.GadgetID, BrandID: r.BrandID, Label: r.Label, Slot: r.Slot}
}

type LensPartWriteResponse struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Slot  int    `json:"slot"`
}

func (LensPartWriteResponse) FromResult(r appqa.LensPartResult) LensPartWriteResponse {
	return LensPartWriteResponse{ID: r.ID.Value(), Label: r.Label, Slot: r.Slot}
}

// ─── Hop 1 reads: qa_lens_parts_view (part + its 1:1 gadget segment) ─────────

// LensGadgetSegmentFilter addresses the MATERIALIZED 1:1 segment. Its Go field
// name ("Gadget") is the embed's Go segment, so the parsed path is
// "Gadget.Code" → the physical "gadget.code" INSIDE the document. Unlike a
// composed leg filter, a miss removes the ROW.
type LensGadgetSegmentFilter struct {
	// ID allowlists row-select by the embedded view's own id — the deep
	// (view-on-view) segment identity, a stored physical column of the source view.
	ID       *string `query:"id"       filter:"eq"`
	Code     *string `query:"code"     filter:"eq,startswith"`
	Name     *string `query:"name"     filter:"eq,icontains"`
	Category *string `query:"category" filter:"eq"`
	Status   *string `query:"status"   filter:"eq"`
}

// LensBrandSegmentFilter addresses the OTHER materialized 1:1 segment.
type LensBrandSegmentFilter struct {
	Name *string `query:"name" filter:"eq,contains"`
}

type FindLensPartsRequest struct {
	KitID    *string `query:"kitId"    filter:"eq"`
	GadgetID *string `query:"gadgetId" filter:"eq"`
	BrandID  *string `query:"brandId"  filter:"eq"`
	Label    *string `query:"label"    filter:"eq,contains,icontains"`
	Slot     *int    `query:"slot"     filter:"eq,gte,lte"`

	Gadget LensGadgetSegmentFilter `query:"gadget"`
	Brand  LensBrandSegmentFilter  `query:"brand"`

	Limit           *int64  `query:"limit"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	Sort            *string `query:"sort"`
	Fields          *string `query:"fields"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

func (r FindLensPartsRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindLensPartsQuery {
	return &appqa.FindLensPartsQuery{Criteria: criteria}
}

// LensGadgetSegmentOutput is the materialized gadget sub-document. Every field
// is a pointer so `?fields=` sparse rendering works INTO the segment. It
// carries the gadget's FULL projection (category/status included) — the visible
// difference from the upstream-mirror segment, which is filtered to
// [id, code, name] by its subscription.
type LensGadgetSegmentOutput struct {
	ID       *string `json:"id,omitempty"`
	Code     *string `json:"code,omitempty"`
	Name     *string `json:"name,omitempty"`
	Category *string `json:"category,omitempty"`
	Status   *string `json:"status,omitempty"`
}

// LensBrandSegmentOutput is the brand sub-document — the DEEPEST hop's content,
// the one the suite watches travel two levels out.
type LensBrandSegmentOutput struct {
	ID   *string `json:"id,omitempty"`
	Name *string `json:"name,omitempty"`
}

type FindLensPartsResponse struct {
	ID       *string                  `json:"id,omitempty"`
	KitID    *string                  `json:"kitId,omitempty"`
	GadgetID *string                  `json:"gadgetId,omitempty"`
	BrandID  *string                  `json:"brandId,omitempty"`
	Label    *string                  `json:"label,omitempty"`
	Slot     *int                     `json:"slot,omitempty"`
	Gadget   *LensGadgetSegmentOutput `json:"gadget,omitempty"`
	Brand    *LensBrandSegmentOutput  `json:"brand,omitempty"`
}

// The by-id requests declare ONLY the recognized query knob: the framework's
// QueryByID binds the path id itself and rejects a Request that redeclares it.
type FindLensPartByIDRequest struct {
	IncludeArchived *bool `query:"includeArchived"`
}

func (r FindLensPartByIDRequest) ToQuery() *appqa.FindLensPartByIDQuery {
	q := &appqa.FindLensPartByIDQuery{}
	if r.IncludeArchived != nil {
		q.IncludeArchived = *r.IncludeArchived
	}
	return q
}

// ─── Hop 2 reads: qa_lens_kits_view (kit + parts[] + parts[].gadget) ────────

// LensPartsSegmentFilter addresses the MATERIALIZED 1:N segment. A predicate
// here still selects ROWS (array matching: the kit is returned when ANY element
// satisfies it) — the elements themselves are never removed by a filter, which
// is precisely the semantic a composed LinkMany inverts.
type LensPartsSegmentFilter struct {
	Label *string `query:"label" filter:"eq,contains"`
	Slot  *int    `query:"slot"  filter:"eq,gte,lte"`
}

type FindLensKitsRequest struct {
	Name *string `query:"name" filter:"eq,contains,icontains"`

	Parts LensPartsSegmentFilter `query:"parts"`

	Limit           *int64  `query:"limit"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	Sort            *string `query:"sort"`
	Fields          *string `query:"fields"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

func (r FindLensKitsRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindLensKitsQuery {
	return &appqa.FindLensKitsQuery{Criteria: criteria}
}

// LensPartSegmentOutput is one element of the kit's 1:N segment — the part's
// own fields PLUS the gadget sub-document hop 1 materialized inside it. This
// nesting is the embed-of-embed proof on the wire.
type LensPartSegmentOutput struct {
	ID       *string                  `json:"id,omitempty"`
	KitID    *string                  `json:"kitId,omitempty"`
	GadgetID *string                  `json:"gadgetId,omitempty"`
	BrandID  *string                  `json:"brandId,omitempty"`
	Label    *string                  `json:"label,omitempty"`
	Slot     *int                     `json:"slot,omitempty"`
	Gadget   *LensGadgetSegmentOutput `json:"gadget,omitempty"`
	Brand    *LensBrandSegmentOutput  `json:"brand,omitempty"`
}

type FindLensKitsResponse struct {
	ID    *string                  `json:"id,omitempty"`
	Name  *string                  `json:"name,omitempty"`
	Parts []*LensPartSegmentOutput `json:"parts,omitempty"`
}

type FindLensKitByIDRequest struct {
	IncludeArchived *bool `query:"includeArchived"`
}

func (r FindLensKitByIDRequest) ToQuery() *appqa.FindLensKitByIDQuery {
	q := &appqa.FindLensKitByIDQuery{}
	if r.IncludeArchived != nil {
		q.IncludeArchived = *r.IncludeArchived
	}
	return q
}
