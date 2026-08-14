//go:build qa

package qafixtures

import "github.com/ClaudioSchirmer/omnicore/domain"

// Widget is a QA-only aggregate root purpose-built to exercise the relational
// reader's unsupported-capability boundary END TO END: a normal query.View over
// it materializes a native child ARRAY (WidgetParts) plus two flat SIBLING facets
// (a root sibling `Material`, a child-level sibling `Tag`). A filter/sort on the
// root field (Name) is served identically by the Mongo and the RelationalSource
// twin (parity); a filter/sort on ANY of the child/sibling fields is a pushdown a
// root SELECT cannot express, so the relational twin returns 400
// RelationalCapabilityNotification while the Mongo view row-selects on it.
type Widget struct {
	domain.AggregateRoot
	Name string
	// Material is a ROOT-level sibling facet — persisted in qa_widget_specs, merged
	// FLAT into the view document (no segment wrapper), so its filter key carries no
	// dot yet its column lives outside the root table.
	Material string
}

func (w *Widget) Modes() []domain.EntityMode {
	return []domain.EntityMode{domain.ModeDisplay, domain.ModeInsert, domain.ModeUpdate}
}

func (w *Widget) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if w.Name == "" {
			r.AddNotification("Name", domain.RequiredFieldNotification{})
		}
	})
}

func (w *Widget) GetAggregateRoot() *domain.AggregateRoot { return &w.AggregateRoot }

func (w *Widget) AggregateChildren() []domain.AggregateValueObject {
	return []domain.AggregateValueObject{WidgetPart{}}
}

func (w *Widget) AddPart(p WidgetPart) {
	domain.AddAggregateChild(w, p)
}

// WidgetPart is a native child of Widget (qa_widget_parts). Label is the child's
// own column; Tag is a CHILD-LEVEL sibling facet (qa_widget_part_tags), merged
// flat into the child sub-document — reached in a filter as the DOTTED path
// widgetParts.tag, the child-level twin of the root sibling.
type WidgetPart struct {
	domain.Managed
	Label string
	Slot  int
	Tag   string
}

func (p WidgetPart) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if p.Label == "" {
			r.AddNotification("Label", domain.RequiredFieldNotification{})
		}
	})
}
