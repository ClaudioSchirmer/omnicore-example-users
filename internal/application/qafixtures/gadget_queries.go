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

// FindGadgetByIDQuery is the by-id read transport. QueryByIDBase supplies
// SetPathID + GetID; ContextName aligns the 404 NotificationContext with the
// singular domain identity ("Gadget").
type FindGadgetByIDQuery struct {
	fwqueries.QueryByIDBase
	IncludeArchived bool
}

func (q FindGadgetByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return fwqueries.ReadCriteria{IncludeArchived: q.IncludeArchived}, nil
}

func (q FindGadgetByIDQuery) ContextName() string { return "Gadget" }

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

// ArchiveGadgetCommand / UnarchiveGadgetCommand are the soft-delete pair (same
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
