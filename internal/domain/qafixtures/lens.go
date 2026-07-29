//go:build qa

package qafixtures

import "github.com/ClaudioSchirmer/omnicore/domain"

// The "lens" family is the MATERIALIZED view-on-view showcase (query.JoinView as
// an embed source), deliberately built as a SIDE family so nothing the upstream
// hack showcases changes shape:
//
//	qa_lens_brands_view ─┐
//	                     ├─1:1 embed→  qa_lens_parts_view  ←1:N embed─  qa_lens_kits_view
//	gadgets (existing) ──┘
//
// A LensPart references a gadget by plain ParentID (write-side strangers, like
// GadgetNote) and its view embeds the LOCAL `gadgets` view. A LensKit references
// nothing; its view embeds the parts view 1:N. So one gadget write ripples two
// hops — the embed-of-embed proof — and each hop is a first-class read surface
// with filters, sort, ?fields= and pagination.

// LensBrand is the DEEPEST root of the chain (qa_lens_brands) — the one this
// family owns end to end, so the suite can observe a VALUE change travelling
// two ripple hops (brand → parts → kits). The `gadgets` embed proves the other
// half: a view this family does NOT own can be materialized just the same.
type LensBrand struct {
	domain.BaseEntity
	Name string
}

func (b *LensBrand) Modes() []domain.EntityMode {
	return []domain.EntityMode{
		domain.ModeDisplay, domain.ModeInsert, domain.ModeUpdate,
		domain.ModeArchive, domain.ModeUnarchive, domain.ModeDelete,
	}
}

func (b *LensBrand) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if b.Name == "" {
			r.AddNotification("Name", domain.RequiredFieldNotification{})
		}
	})
}

// LensKit is the outer aggregate root (qa_lens_kits): flat, one business field.
type LensKit struct {
	domain.BaseEntity
	Name string
}

func (k *LensKit) Modes() []domain.EntityMode {
	return []domain.EntityMode{
		domain.ModeDisplay, domain.ModeInsert, domain.ModeUpdate,
		domain.ModeArchive, domain.ModeUnarchive, domain.ModeDelete,
	}
}

func (k *LensKit) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if k.Name == "" {
			r.AddNotification("Name", domain.RequiredFieldNotification{})
		}
	})
}

// LensPart is the middle aggregate root (qa_lens_parts): it carries the ParentID to
// its kit (the 1:N join the kits view embeds on) and the ParentID to a gadget (the 1:1
// join its own view embeds on). Both are plain columns — no aggregate child, no
// shared base — so every relationship in this family is a materialized JOIN, not
// a write-side containment.
type LensPart struct {
	domain.BaseEntity
	KitID    *string
	GadgetID *string
	BrandID  *string
	Label    string
	Slot     int
}

func (p *LensPart) Modes() []domain.EntityMode {
	return []domain.EntityMode{
		domain.ModeDisplay, domain.ModeInsert, domain.ModeUpdate,
		domain.ModeArchive, domain.ModeUnarchive, domain.ModeDelete,
	}
}

func (p *LensPart) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if p.Label == "" {
			r.AddNotification("Label", domain.RequiredFieldNotification{})
		}
	})
}
