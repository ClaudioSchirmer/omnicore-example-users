//go:build qa

package qafixtures

import (
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/domain"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
)

// ─── GadgetNote write + own list ─────────────────────────────────────────────

// InsertGadgetNoteRequest is the JSON body of POST /qa/gadget-notes.
type InsertGadgetNoteRequest struct {
	GadgetID string `json:"gadgetId" example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Text     string `json:"text"     example:"handle with care"`
	Kind     string `json:"kind"     example:"public"`
}

func (r InsertGadgetNoteRequest) ToCommand() *appqa.InsertGadgetNoteCommand {
	return &appqa.InsertGadgetNoteCommand{GadgetID: r.GadgetID, Text: r.Text, Kind: r.Kind}
}

// InsertGadgetNoteResponse is the wire shape of a successful note insert.
type InsertGadgetNoteResponse struct {
	ID       domain.ID `json:"id"       example:"0f2c7d4e-9a1b-4c3d-8e5f-6a7b8c9d0e1f"`
	GadgetID string    `json:"gadgetId" example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Text     string    `json:"text"     example:"handle with care"`
	Kind     string    `json:"kind"     example:"public"`
}

func (InsertGadgetNoteResponse) FromResult(r appqa.InsertGadgetNoteResult) InsertGadgetNoteResponse {
	return InsertGadgetNoteResponse{ID: r.ID, GadgetID: r.GadgetID, Text: r.Text, Kind: r.Kind}
}

// FindGadgetNotesRequest is the wire allowlist of GET /qa/gadget-notes — the
// leg view read directly, proving a composed leg stays a first-class view.
type FindGadgetNotesRequest struct {
	GadgetID *string `query:"gadgetId" filter:"eq"`
	Text     *string `query:"text"     filter:"eq,contains"`
	Kind     *string `query:"kind"     filter:"eq"`

	First           *int64  `query:"first"`
	Last            *int64  `query:"last"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

func (r FindGadgetNotesRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindGadgetNotesQuery {
	return &appqa.FindGadgetNotesQuery{Criteria: criteria}
}

// FindGadgetNotesResponse is the per-item wire projection of the note list.
type FindGadgetNotesResponse struct {
	fwresponses.Auto
	ID       *string `json:"id,omitempty"`
	GadgetID *string `json:"gadgetId,omitempty"`
	Text     *string `json:"text,omitempty"`
	Kind     *string `json:"kind,omitempty"`
}

func (FindGadgetNotesResponse) FromResult(r appqa.FindGadgetNotesResult) FindGadgetNotesResponse {
	return fwresponses.AutoFromResult[FindGadgetNotesResponse](r)
}

// ─── Composed reads (gadgets_full) ───────────────────────────────────────────

// FindGadgetsFullRequest is the wire allowlist of GET /qa/gadgets-full — the
// paged COMPOSED read. Root leaves filter the PRIMARY (they select rows);
// the nested `notes` group addresses the LinkMany segment (it filters what
// enters each item's Notes array, never which gadgets appear — R2). A `?orderBy=`
// into `notes.*` is rejected with 400: segment order is declared on the link.
type FindGadgetsFullRequest struct {
	Code *string `query:"code" filter:"eq,startswith" sort:"asc,desc"`
	Name *string `query:"name" filter:"eq,icontains" sort:"asc,desc"`

	Notes          GadgetFullNotesFilter  `query:"notes"`
	UpstreamMirror GadgetFullMirrorFilter `query:"upstreamMirror"`

	First           *int64  `query:"first"`
	Last            *int64  `query:"last"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	Fields          *string `query:"fields"`
	Search          *string `query:"search"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
	OrderBy         *string `query:"orderBy"`
}

// GadgetFullNotesFilter is the 1:N segment filter group. Its Go field name on
// the request ("Notes") matches the link's Go segment, so the parsed criteria
// carry segment-prefixed paths ("Notes.Text") the composed reader routes to
// the leg fetch.
type GadgetFullNotesFilter struct {
	Text *string `query:"text" filter:"eq,contains"`
	Kind *string `query:"kind" filter:"eq"`
}

// GadgetFullMirrorFilter is the 1:1 segment filter group: an unmatched filter
// nulls the sub-document (segment content shaping), never the row.
type GadgetFullMirrorFilter struct {
	Code *string `query:"code" filter:"eq"`
}

func (r FindGadgetsFullRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindGadgetsFullQuery {
	return &appqa.FindGadgetsFullQuery{Criteria: criteria}
}

// FindGadgetsFullResponse is the per-item wire projection of the composed
// list. Every field (at every depth) is a pointer / omitempty slice so
// `?fields=` sparse rendering works — including into the segments
// (`?fields=code,notes.text`).
type FindGadgetsFullResponse struct {
	fwresponses.Auto
	ID             *string                 `json:"id,omitempty"`
	Code           *string                 `json:"code,omitempty"`
	Name           *string                 `json:"name,omitempty"`
	Category       *string                 `json:"category,omitempty"`
	Status         *string                 `json:"status,omitempty"`
	UpstreamMirror *GadgetFullMirrorOutput `json:"upstreamMirror,omitempty"`
	Notes          []GadgetFullNoteOutput  `json:"notes,omitempty"`
}

// FromResult is the wire mapping seat of the composed list — also the seat the
// CSV/XLSX exports project through, so the tabular branches are exactly the
// segments this DTO declares.
func (FindGadgetsFullResponse) FromResult(r appqa.FindGadgetsFullResult) FindGadgetsFullResponse {
	return fwresponses.AutoFromResult[FindGadgetsFullResponse](r)
}

// GadgetFullMirrorOutput is the 1:1 external segment: null while the upstream
// copy is not materialized (LEFT semantics) — the same [id, code, name] shape
// the subscription filter allows.
type GadgetFullMirrorOutput struct {
	ID   *string `json:"id,omitempty"`
	Code *string `json:"code,omitempty"`
	Name *string `json:"name,omitempty"`
}

// GadgetFullNoteOutput is one entry of the 1:N segment ("the first 3 in the
// declared order", per the link's MaxLinkManyLimit).
type GadgetFullNoteOutput struct {
	ID   *string `json:"id,omitempty"`
	Text *string `json:"text,omitempty"`
	Kind *string `json:"kind,omitempty"`
}

// FindGadgetFullByIDRequest is the wire allowlist of GET /qa/gadgets-full/:id.
type FindGadgetFullByIDRequest struct {
	IncludeArchived *bool `query:"includeArchived"`
}

func (r FindGadgetFullByIDRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindGadgetFullByIDQuery {
	return &appqa.FindGadgetFullByIDQuery{Criteria: criteria}
}

// FindGadgetFullByIDResponse is the composed by-id projection: the flat
// gadget + the 1:1 upstream mirror (null when absent) + the notes window.
// The by-id query overlays "Notes.Kind" = "public" in ToCriteria (R9), so an
// internal note NEVER surfaces here while remaining visible on the leg's own
// surface (GET /qa/gadget-notes).
type FindGadgetFullByIDResponse struct {
	fwresponses.Auto
	ID             string                  `json:"id"`
	Code           string                  `json:"code"`
	Name           string                  `json:"name"`
	Category       string                  `json:"category"`
	Status         string                  `json:"status"`
	UpstreamMirror *GadgetFullMirrorOutput `json:"upstreamMirror,omitempty"`
	Notes          []GadgetFullNoteOutput  `json:"notes"`
}

func (FindGadgetFullByIDResponse) FromResult(r appqa.FindGadgetFullByIDResult) FindGadgetFullByIDResponse {
	return fwresponses.AutoFromResult[FindGadgetFullByIDResponse](r)
}
