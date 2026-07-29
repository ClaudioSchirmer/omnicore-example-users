//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// GadgetKitLineInput is one native child line: GadgetID is the ParentID the view
// enriches via EmbedInChild (→ upstream_gadgets._id); Note is the line's own.
type GadgetKitLineInput struct {
	GadgetID *string
	Note     string
}

// InsertGadgetKitCommand creates a kit with its native child lines.
type InsertGadgetKitCommand struct {
	pipeline.CommandWithBodyBase
	Name  string
	Lines []GadgetKitLineInput
}

func (c *InsertGadgetKitCommand) ToEntity(_ *configuration.AppContext) (*qadomain.GadgetKit, error) {
	k := &qadomain.GadgetKit{Name: c.Name}
	for _, l := range c.Lines {
		k.AddLine(qadomain.GadgetKitLine{GadgetID: l.GadgetID, Note: l.Note})
	}
	return k, nil
}

func (c *InsertGadgetKitCommand) FromEntity(_ *configuration.AppContext, k *qadomain.GadgetKit) (GadgetKitResult, error) {
	return GadgetKitResult{ID: *k.GetID(), Name: k.Name}, nil
}

// GadgetKitResult is the application-layer projection of the insert.
type GadgetKitResult struct {
	ID   domain.ID
	Name string
}

var _ pipeline.InsertCommand[*qadomain.GadgetKit, GadgetKitResult] = (*InsertGadgetKitCommand)(nil)

// FindGadgetKitByIDQuery reads the composed qa_gadget_kits_view document (the
// kit + its enriched child lines).
type FindGadgetKitByIDQuery struct {
	fwqueries.QueryByIDBase
	IncludeArchived bool
}

func (q FindGadgetKitByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return fwqueries.ReadCriteria{IncludeArchived: q.IncludeArchived}, nil
}

func (q FindGadgetKitByIDQuery) ContextName() string { return "GadgetKit" }

// FindGadgetKitsQuery is the paged LIST read (root + nested enriched-child
// filters, sort, ?fields=, pagination).
type FindGadgetKitsQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindGadgetKitsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}
