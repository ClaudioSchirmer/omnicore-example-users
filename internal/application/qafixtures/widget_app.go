//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// WidgetPartInput is one native child part: Label + Slot are the part's own; Tag
// is its child-level sibling facet.
type WidgetPartInput struct {
	Label string
	Slot  int
	Tag   string
}

// InsertWidgetCommand creates a widget with its root Material sibling and its
// native child parts (each carrying a Tag sibling).
type InsertWidgetCommand struct {
	pipeline.CommandWithBodyBase
	Name     string
	Material string
	Parts    []WidgetPartInput
}

func (c *InsertWidgetCommand) ToEntity(_ *configuration.AppContext) (*qadomain.Widget, error) {
	w := &qadomain.Widget{Name: c.Name, Material: c.Material}
	for _, p := range c.Parts {
		w.AddPart(qadomain.WidgetPart{Label: p.Label, Slot: p.Slot, Tag: p.Tag})
	}
	return w, nil
}

func (c *InsertWidgetCommand) FromEntity(_ *configuration.AppContext, w *qadomain.Widget) (WidgetResult, error) {
	return WidgetResult{ID: *w.GetID(), Name: w.Name}, nil
}

// WidgetResult is the application-layer projection of the insert.
type WidgetResult struct {
	ID   domain.ID
	Name string
}

var _ pipeline.InsertCommand[*qadomain.Widget, WidgetResult] = (*InsertWidgetCommand)(nil)

// FindWidgetByIDQuery reads the qa_widgets_view document (widget + Material + the
// WidgetParts array).
type FindWidgetByIDQuery struct {
	fwqueries.QueryByIDBase
	Criteria fwqueries.ReadCriteria
}

func (q FindWidgetByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

func (q FindWidgetByIDQuery) FromQueryResult(_ *configuration.AppContext, r FindWidgetsResult) (FindWidgetsResult, error) {
	return r, nil
}

func (q FindWidgetByIDQuery) ContextName() string { return "Widget" }

// FindWidgetsQuery is the paged LIST read (root + child/sibling filters, sort,
// ?fields=, pagination). The SAME query serves the Mongo view and the
// RelationalSource twin — only the target view name differs at the route.
type FindWidgetsQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindWidgetsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

func (q FindWidgetsQuery) FromQueryResult(_ *configuration.AppContext, r FindWidgetsResult) (FindWidgetsResult, error) {
	return r, nil
}

// FindWidgetsResult is the application Result of one widget document: the
// root, its flat Material sibling and the WidgetParts child array. The by-id
// read serves the SAME wire shape, so it shares this Result — one document
// shape, one Result. Pointers throughout: the list endpoint opts into
// `?fields=`.
type FindWidgetsResult struct {
	ID          *string
	Name        *string
	Material    *string
	WidgetParts []WidgetPartResult
}

// WidgetPartResult is one element of the WidgetParts child array (its own
// fields plus the flat child-level sibling Tag).
type WidgetPartResult struct {
	Label *string
	Slot  *int
	Tag   *string
}
