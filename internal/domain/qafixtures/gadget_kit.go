//go:build qa

package qafixtures

import "github.com/ClaudioSchirmer/omnicore/domain"

// GadgetKit is a flat aggregate root (qa_gadget_kits) whose native child lines
// each reference a gadget — the EmbedInChild proof over the `upstream_gadgets`
// projection (the SAME upstream the gadgets_embedded view uses), kept apart from
// GadgetSchema so no existing gadget view changes shape. Each line's GadgetID is
// enriched with the upstream gadget mirror (code/name) by qa_gadget_kits_view.
type GadgetKit struct {
	domain.AggregateRoot
	Name string
}

func (k *GadgetKit) Modes() []domain.EntityMode {
	return []domain.EntityMode{domain.ModeDisplay, domain.ModeInsert, domain.ModeUpdate}
}

func (k *GadgetKit) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if k.Name == "" {
			r.AddNotification("Name", domain.RequiredFieldNotification{})
		}
	})
}

// GadgetKitLine is a native child of GadgetKit (qa_gadget_kit_lines): GadgetID
// is the ParentID the view enriches via EmbedInChild (→ upstream_gadgets._id); Note is
// the line's own field.
type GadgetKitLine struct {
	domain.Managed
	GadgetID *string
	Note     string
}

func (l GadgetKitLine) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if l.Note == "" {
			r.AddNotification("Note", domain.RequiredFieldNotification{})
		}
	})
}

func (k *GadgetKit) GetAggregateRoot() *domain.AggregateRoot { return &k.AggregateRoot }

func (k *GadgetKit) AggregateChildren() []domain.AggregateValueObject {
	return []domain.AggregateValueObject{GadgetKitLine{}}
}

func (k *GadgetKit) AddLine(l GadgetKitLine) {
	domain.EnsureInitialized(k)
	domain.AddAggregateChild(k, l)
}
