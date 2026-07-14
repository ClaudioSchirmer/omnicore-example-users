//go:build qa

package qafixtures

import "github.com/ClaudioSchirmer/omnicore/domain"

// GadgetNote is a second FLAT aggregate root, deliberately minimal: one row
// per free-form note attached to a gadget by plain foreign key (gadget_notes.
// gadget_id → gadgets.id). It exists as the 1:N counterpart of the composed
// read showcase: `gadget_notes` is a regular view of its own AND the LinkMany
// leg of the `gadgets_full` ComposedView — proving a read-time join between
// two aggregates that share no write-side declaration (no child, no shared
// base, no embed).
//
// Kind is a closed set ("public" / "internal"): the composed by-id read
// demonstrates the per-leg authorization seam (the Query's ToCriteria overlays
// a segment filter hiding internal notes), while the note's own view shows
// everything.
type GadgetNote struct {
	domain.AggregateRoot
	GadgetID domain.ID
	Text     string
	Kind     string
}

// Modes advertises the lifecycle verbs; SoftDelete on the schema pairs with
// ModeArchive/ModeUnarchive so the composed leg's archived gate is exercisable.
func (n *GadgetNote) Modes() []domain.EntityMode {
	return []domain.EntityMode{
		domain.ModeDisplay,
		domain.ModeInsert,
		domain.ModeDelete,
		domain.ModeArchive,
		domain.ModeUnarchive,
	}
}

// gadgetNoteKinds is the closed set Kind must fall into.
var gadgetNoteKinds = map[string]struct{}{
	"public":   {},
	"internal": {},
}

// BuildRules: GadgetID + Text are required; Kind must be in the closed set.
// All three notifications are framework built-ins, so no service translation
// entry is needed.
func (n *GadgetNote) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if n.GadgetID.IsEmpty() {
			r.AddNotification("GadgetID", domain.RequiredFieldNotification{})
		}
		if n.Text == "" {
			r.AddNotification("Text", domain.RequiredFieldNotification{})
		}
		if _, ok := gadgetNoteKinds[n.Kind]; !ok {
			r.AddNotification("Kind", domain.SchemaViolationNotification{}, n.Kind)
		}
	})
}
