//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// FindGadgetsQuery is the application transport for a paged Gadget read. The
// wrapper has already parsed the query string into the embedded ReadCriteria;
// ToCriteria applies any identity-derived overlay (none here).
type FindGadgetsQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindGadgetsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

// FromQueryResult is the read-side twin of a command's FromEntity: the framework
// fills one Result per returned document and hands it here BEFORE any
// transport surface sees it. This listing needs no computation.
// FromQueryResult derives the COMPUTED Label from the two stored sources. It
// runs once per document, before any surface sees the value, so REST, the
// tabular exports and GraphQL all render the same derivation — the whole
// reason read-side computation lives at this seat.
func (q FindGadgetsQuery) FromQueryResult(_ *configuration.AppContext, r FindGadgetsResult) (FindGadgetsResult, error) {
	r.Label = computeGadgetLabel(r.Code, r.Name)
	return r, nil
}

// FindGadgetsResult is the application-layer Result of one gadget document in
// the paged listing — pure data, NO wire tags (wire naming belongs to the web
// Response), field names identical to the view document's Go keys. Every
// field is a pointer because the endpoint opts into `?fields=`: a
// projected-out column must fill as absent, not as a zero value.
type FindGadgetsResult struct {
	ID       *string
	Code     *string
	Name     *string
	Category *string
	Status   *string
	// Label is COMPUTED — no column backs it. FromQueryResult derives it from
	// Code+Name below, and a Response that wants it declares
	// `computed:"Code,Name"` so `?fields=label` reads those two instead. A
	// Response that does NOT declare it simply never renders it, proving an
	// extra Result field cannot leak to a wire that did not ask for it.
	Label *string
}

// computeGadgetLabel derives the Label from the two sources. Kept beside the
// Result so both the list and the by-id query fill it identically.
func computeGadgetLabel(code, name *string) *string {
	if code == nil || name == nil {
		return nil
	}
	label := *code + " · " + *name
	return &label
}

// FindGadgetByIDQuery is the by-id read transport. QueryByIDBase supplies
// SetPathID + GetID; ContextName aligns the 404 NotificationContext with the
// singular domain identity ("Gadget").
type FindGadgetByIDQuery struct {
	fwqueries.QueryByIDBase
	Criteria fwqueries.ReadCriteria
}

func (q FindGadgetByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

func (q FindGadgetByIDQuery) FromQueryResult(_ *configuration.AppContext, r FindGadgetByIDResult) (FindGadgetByIDResult, error) {
	return r, nil
}

func (q FindGadgetByIDQuery) ContextName() string { return "Gadget" }

// FindGadgetByIDResult is the by-id Result. The query serves TWO views over
// the same root — the flat `gadgets` projection and the composed
// `gadgets_embedded` one — so the Result carries the union: the flat gadget
// plus the optional one-to-one upstream mirror. The by-id endpoints declare
// no `?fields=`, so the flat leaves are plain values; UpstreamMirror stays a
// pointer because the composer genuinely omits it until the upstream copy is
// materialized.
type FindGadgetByIDResult struct {
	ID             string
	Code           string
	Name           string
	Category       string
	Status         string
	UpstreamMirror *GadgetUpstreamMirrorResult
}

// GadgetUpstreamMirrorResult is the nested Result of the `upstream_gadgets`
// mirror segment — only [ID, Code, Name] survive the subscription filter.
type GadgetUpstreamMirrorResult struct {
	ID   string
	Code string
	Name string
}

// DeleteGadgetCommand triggers a hard delete; the id comes from the URL path.
type DeleteGadgetCommand struct{ pipeline.CommandByIDBase }

// ApplyTo is the ctx → business translation hook on the delete verb (no-op).
func (*DeleteGadgetCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.Gadget) error {
	return nil
}

// FromEntity returns the bodyless result shape.
func (*DeleteGadgetCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.Gadget) (fwresults.None, error) {
	return fwresults.None{}, nil
}

// ArchiveGadgetCommand / UnarchiveGadgetCommand are the DeletedAt pair (same
// bodyless, id-from-path shape as delete). They exist so the DeleteOnArchive
// read-side option is exercisable end to end: archiving a gadget drops it from
// the `gadgets_hot` view (which opts into DeleteOnArchive) while it survives,
// hidden, in the default keep-by-default `gadgets` view.
type ArchiveGadgetCommand struct{ pipeline.CommandByIDBase }

func (*ArchiveGadgetCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.Gadget) error {
	return nil
}
func (*ArchiveGadgetCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.Gadget) (fwresults.None, error) {
	return fwresults.None{}, nil
}

type UnarchiveGadgetCommand struct{ pipeline.CommandByIDBase }

func (*UnarchiveGadgetCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.Gadget) error {
	return nil
}
func (*UnarchiveGadgetCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.Gadget) (fwresults.None, error) {
	return fwresults.None{}, nil
}
