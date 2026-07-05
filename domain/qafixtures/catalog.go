//go:build qa

package qafixtures

import "github.com/ClaudioSchirmer/omnicore/domain"

// Catalog is a NORMAL (non-shared-base) flat aggregate root — the counterpart of
// AccountHolder for proving external embeds on a REGULAR query.View, not just a
// SharedBaseView. Its qa_catalog_view embeds the SAME `upstream_items`
// projection 1:1 (Embed "featuredItem", via FeaturedItemID) AND 1:N (EmbedMany
// "items", via upstream_items.catalog_id → this catalog id). Together with the
// AccountHolder shared-base view, this covers the full matrix: {normal,
// shared-base} × {Embed 1:1, EmbedMany 1:N}.
//
// FeaturedItemID is the nullable 1:1 embed FK (→ an upstream_items _id). The 1:N
// side needs no column here — items point back via their own catalog_id.
type Catalog struct {
	domain.AggregateRoot
	Name           string
	FeaturedItemID *string
}

func (c *Catalog) Modes() []domain.EntityMode {
	return []domain.EntityMode{
		domain.ModeDisplay,
		domain.ModeInsert,
		domain.ModeUpdate,
	}
}

func (c *Catalog) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if c.Name == "" {
			r.AddNotification("Name", domain.RequiredFieldNotification{})
		}
	})
}
