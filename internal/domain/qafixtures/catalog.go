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

// CatalogLine is a NATIVE aggregate child of Catalog (qa_catalog_lines) — the
// proof target for EmbedInChild: each line carries ItemID (a FK into the
// upstream_items projection) plus its own field Note; the qa_catalog_view
// enriches each line with the item (name/label) via EmbedInChild, keeping the
// write model normalized (the line stores only the FK). Value type so the
// framework's aggregate primitives compare by field equality.
type CatalogLine struct {
	ID     domain.ID
	ItemID *string // FK → upstream_items._id; the EmbedInChild join key (nullable)
	Note   string
}

func (l CatalogLine) GetID() domain.ID { return l.ID }

func (l CatalogLine) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if l.Note == "" {
			r.AddNotification("Note", domain.RequiredFieldNotification{})
		}
	})
}

// ─── domain.AggregateRootProvider (Catalog owns CatalogLine children) ─────────

func (c *Catalog) GetAggregateRoot() *domain.AggregateRoot { return &c.AggregateRoot }

func (c *Catalog) AggregateChildren() []domain.AggregateValueObject {
	return []domain.AggregateValueObject{CatalogLine{}}
}

// AddLine attaches a CatalogLine to the aggregate (INSERT on commit).
func (c *Catalog) AddLine(l CatalogLine) {
	domain.EnsureInitialized(c)
	domain.AddAggregateChild(c, l)
}

// ReplaceLines clears and re-adds the whole line collection (PUT full-replace).
func (c *Catalog) ReplaceLines(lines []CatalogLine) {
	domain.EnsureInitialized(c)
	domain.ReplaceAggregateChildrenOf(c, lines)
}
