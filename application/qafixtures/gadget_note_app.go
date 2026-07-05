//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/domain/qafixtures"
)

// ─── GadgetNote commands ─────────────────────────────────────────────────────

// InsertGadgetNoteCommand is the "attach a note to a gadget" use case — a
// plain flat insert (no hooks; the hook showcase belongs to the Gadget).
type InsertGadgetNoteCommand struct {
	pipeline.CommandBase
	GadgetID string
	Text     string
	Kind     string
}

func (c *InsertGadgetNoteCommand) ToEntity(_ *configuration.AppContext) (*qadomain.GadgetNote, error) {
	return &qadomain.GadgetNote{GadgetID: c.GadgetID, Text: c.Text, Kind: c.Kind}, nil
}

func (c *InsertGadgetNoteCommand) FromEntity(_ *configuration.AppContext, n *qadomain.GadgetNote) (InsertGadgetNoteResult, error) {
	return InsertGadgetNoteResult{
		ID:       *n.GetID(),
		GadgetID: n.GadgetID,
		Text:     n.Text,
		Kind:     n.Kind,
	}, nil
}

// InsertGadgetNoteResult is the application-layer projection of the insert.
type InsertGadgetNoteResult struct {
	ID       domain.ID
	GadgetID string
	Text     string
	Kind     string
}

var _ pipeline.InsertCommand[*qadomain.GadgetNote, InsertGadgetNoteResult] = (*InsertGadgetNoteCommand)(nil)

// ArchiveGadgetNoteCommand / UnarchiveGadgetNoteCommand are the soft-delete
// pair, exercised by the composed suite: an archived note vanishes from the
// composed `Notes` segment on default reads (the leg's own gate) and returns
// under ?includeArchived — the R8 per-leg behavior, observed end to end.
type ArchiveGadgetNoteCommand struct{ pipeline.CommandBaseWithID }

func (*ArchiveGadgetNoteCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.GadgetNote) error {
	return nil
}
func (*ArchiveGadgetNoteCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.GadgetNote) (fwresults.None, error) {
	return fwresults.None{}, nil
}

type UnarchiveGadgetNoteCommand struct{ pipeline.CommandBaseWithID }

func (*UnarchiveGadgetNoteCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.GadgetNote) error {
	return nil
}
func (*UnarchiveGadgetNoteCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.GadgetNote) (fwresults.None, error) {
	return fwresults.None{}, nil
}

// ─── GadgetNote query (the leg's OWN surface) ────────────────────────────────

// FindGadgetNotesQuery is the paged read of the `gadget_notes` view itself —
// the leg is a first-class view; the composed segment is a windowed LEFT-join
// projection of it. No overlays: this surface shows every note (including
// kind=internal), which is what makes the composed by-id overlay observable.
type FindGadgetNotesQuery struct {
	pipeline.QueryBase
	Criteria fwqueries.ReadCriteria
}

func (q FindGadgetNotesQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

// ─── Composed reads (gadgets_full) ───────────────────────────────────────────

// FindGadgetsFullQuery is the paged composed read. ToCriteria applies NO
// overlay here: the paged surface exercises the full cursor machinery, and a
// deterministic ToCriteria filter overlay would change the reader-side context
// hash that the wire layer pre-validates cursors against (the same framework
// posture every overlay-bearing paged view has today). The per-leg overlay
// showcase (R9) lives on the by-id query below, where no cursor exists.
type FindGadgetsFullQuery struct {
	pipeline.QueryBase
	Criteria fwqueries.ReadCriteria
}

func (q FindGadgetsFullQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

// FindGadgetFullByIDQuery is the composed by-id read AND the per-leg
// authorization showcase (R9): ToCriteria overlays a segment-prefixed filter
// ("Notes.Kind" = "public") through the same channel wire segment filters
// travel, so the composed surface NEVER exposes internal notes — regardless of
// what the wire asked — while the leg's own view (GET /qa/gadget-notes) still
// shows them. The overlay filters what enters the segment; it can never select
// or leak primary rows (framework guarantee, R2).
type FindGadgetFullByIDQuery struct {
	fwqueries.QueryBaseWithID
	IncludeArchived bool
}

func (q FindGadgetFullByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return fwqueries.ReadCriteria{
		IncludeArchived: q.IncludeArchived,
		// The per-leg overlay: full developer responsibility, declared here in
		// ToCriteria (D1/R9) — the single read-side authz seam. Segment paths
		// resolve at every level of the linked document.
		Filter: map[string]any{"Notes.Kind": "public"},
	}, nil
}

func (q FindGadgetFullByIDQuery) ContextName() string { return "Gadget" }
