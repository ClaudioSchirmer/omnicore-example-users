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
	Criteria fwqueries.ReadCriteria
}

func (q FindGadgetKitByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

func (q FindGadgetKitByIDQuery) FromQueryResult(_ *configuration.AppContext, r FindGadgetKitByIDResult) (FindGadgetKitByIDResult, error) {
	return r, nil
}

func (q FindGadgetKitByIDQuery) ContextName() string { return "GadgetKit" }

// FindGadgetKitByIDResult is the by-id Result: the kit plus its enriched
// child lines. The by-id endpoint declares no `?fields=`, so the root leaves
// are plain values.
type FindGadgetKitByIDResult struct {
	ID             string
	Name           string
	GadgetKitLines []GadgetKitLineResult
}

// GadgetKitLineResult is one enriched native child line — its own fields plus
// the EmbedInChild `Gadget` sub-document.
type GadgetKitLineResult struct {
	GadgetID *string
	Note     *string
	Gadget   *GadgetMirrorResult
}

// GadgetMirrorResult is one embedded `upstream_gadgets` document (the
// enrichment); field names match the mirror's external schema Go names.
type GadgetMirrorResult struct {
	ID   *string
	Code *string
	Name *string
}

// FindGadgetKitsQuery is the paged LIST read (root + nested enriched-child
// filters, sort, ?fields=, pagination).
type FindGadgetKitsQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindGadgetKitsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

func (q FindGadgetKitsQuery) FromQueryResult(_ *configuration.AppContext, r FindGadgetKitsResult) (FindGadgetKitsResult, error) {
	return r, nil
}

// FindGadgetKitsResult is the paged listing's Result — pointers/slices
// throughout because the endpoint opts into `?fields=`, including into the
// enriched child lines.
type FindGadgetKitsResult struct {
	ID             *string
	Name           *string
	GadgetKitLines []GadgetKitLineResult
}
