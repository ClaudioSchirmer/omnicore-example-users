//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// ─── GadgetNote commands ─────────────────────────────────────────────────────

// InsertGadgetNoteCommand is the "attach a note to a gadget" use case — a
// plain flat insert (no hooks; the hook showcase belongs to the Gadget).
type InsertGadgetNoteCommand struct {
	pipeline.CommandWithBodyBase
	GadgetID string
	Text     string
	Kind     string
}

func (c *InsertGadgetNoteCommand) ToEntity(_ *configuration.AppContext) (*qadomain.GadgetNote, error) {
	return &qadomain.GadgetNote{GadgetID: domain.NewID(c.GadgetID), Text: c.Text, Kind: c.Kind}, nil
}

func (c *InsertGadgetNoteCommand) FromEntity(_ *configuration.AppContext, n *qadomain.GadgetNote) (InsertGadgetNoteResult, error) {
	return InsertGadgetNoteResult{
		ID:       *n.GetID(),
		GadgetID: n.GadgetID.Value(),
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

// ArchiveGadgetNoteCommand / UnarchiveGadgetNoteCommand are the DeletedAt
// pair, exercised by the composed suite: an archived note vanishes from the
// composed `Notes` segment on default reads (the leg's own gate) and returns
// under ?includeArchived — the R8 per-leg behavior, observed end to end.
type ArchiveGadgetNoteCommand struct{ pipeline.CommandByIDBase }

func (*ArchiveGadgetNoteCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.GadgetNote) error {
	return nil
}
func (*ArchiveGadgetNoteCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.GadgetNote) (fwresults.None, error) {
	return fwresults.None{}, nil
}

type UnarchiveGadgetNoteCommand struct{ pipeline.CommandByIDBase }

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
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindGadgetNotesQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

func (q FindGadgetNotesQuery) FromQueryResult(_ *configuration.AppContext, r FindGadgetNotesResult) (FindGadgetNotesResult, error) {
	return r, nil
}

// FindGadgetNotesResult is the application Result of one `gadget_notes`
// document — pure data, no wire tags, field names identical to the view
// document's Go keys.
type FindGadgetNotesResult struct {
	ID       *string
	GadgetID *string
	Text     *string
	Kind     *string
}

// ─── Composed reads (gadgets_full) ───────────────────────────────────────────

// FindGadgetsFullQuery is the paged composed read AND the security-overlay ×
// pagination showcase: ToCriteria layers a ROW overlay ("Status" = "active")
// onto whatever the wire asked, exactly like a tenant/owner gate would — the
// composed surface never serves non-active gadgets, regardless of the query
// string. Cursor navigation keeps working WITH the overlay because the
// context-hash validation is authoritative at the reader, post-ToCriteria
// (the wire layer performs structural cursor checks only) — the guarantee
// that a developer adding a security filter never breaks pagination.
type FindGadgetsFullQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindGadgetsFullQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	crit := q.Criteria
	if crit.Filter == nil {
		crit.Filter = map[string]any{}
	}
	// Security-style row overlay: identical seam a tenant gate uses
	// (crit.Filter["TenantID"] = ctx.Identity()...); deterministic here so the
	// QA suite can assert it without an authenticated identity.
	crit.Filter["Status"] = "active"
	return crit, nil
}

func (q FindGadgetsFullQuery) FromQueryResult(_ *configuration.AppContext, r FindGadgetsFullResult) (FindGadgetsFullResult, error) {
	return r, nil
}

// FindGadgetsFullResult is the composed listing's Result: the primary gadget
// plus the two read-time legs. Every field is a pointer / slice because the
// endpoint opts into `?fields=` — including into the segments.
type FindGadgetsFullResult struct {
	ID             *string
	Code           *string
	Name           *string
	Category       *string
	Status         *string
	UpstreamMirror *GadgetFullMirrorResult
	Notes          []GadgetFullNoteResult
}

// GadgetFullMirrorResult is the 1:1 external leg — null while the upstream
// copy is not materialized (LEFT semantics).
type GadgetFullMirrorResult struct {
	ID   *string
	Code *string
	Name *string
}

// GadgetFullNoteResult is one entry of the 1:N internal leg.
type GadgetFullNoteResult struct {
	ID   *string
	Text *string
	Kind *string
}

// FindGadgetFullByIDQuery is the composed by-id read AND the per-leg
// authorization showcase (R9): ToCriteria overlays a segment-prefixed filter
// ("Notes.Kind" = "public") through the same channel wire segment filters
// travel, so the composed surface NEVER exposes internal notes — regardless of
// what the wire asked — while the leg's own view (GET /qa/gadget-notes) still
// shows them. The overlay filters what enters the segment; it can never select
// or leak primary rows (framework guarantee, R2).
type FindGadgetFullByIDQuery struct {
	fwqueries.QueryByIDBase
	Criteria fwqueries.ReadCriteria
}

func (q FindGadgetFullByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	crit := q.Criteria
	crit.Filter = map[string]any{
		// The per-leg overlay: full developer responsibility, declared here
		// in ToCriteria (D1/R9) — the single read-side authz seam. Segment
		// paths resolve at every level of the linked document.
		"Notes.Kind": "public",
		// The same row overlay the paged surface applies: the composed
		// surface as a whole never serves non-active gadgets (404 here).
		"Status": "active",
	}
	return crit, nil
}

func (q FindGadgetFullByIDQuery) FromQueryResult(_ *configuration.AppContext, r FindGadgetFullByIDResult) (FindGadgetFullByIDResult, error) {
	return r, nil
}

func (q FindGadgetFullByIDQuery) ContextName() string { return "Gadget" }

// FindGadgetFullByIDResult is the composed by-id Result: the flat gadget plus
// the 1:1 mirror (absent until materialized) and the notes window. The by-id
// endpoint declares no `?fields=`, so the primary's own leaves are plain
// values; the legs keep their LEFT-join optionality.
type FindGadgetFullByIDResult struct {
	ID             string
	Code           string
	Name           string
	Category       string
	Status         string
	UpstreamMirror *GadgetFullMirrorResult
	Notes          []GadgetFullNoteResult
}
