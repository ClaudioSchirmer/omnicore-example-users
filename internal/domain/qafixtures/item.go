//go:build qa

package qafixtures

import "github.com/ClaudioSchirmer/omnicore/domain"

// Item is a FLAT aggregate root that exists ONLY to be the EXTERNAL embed
// source of the shared-base `qa_accounts_view` (see infra/qafixtures/
// account_infra.go). Written through the normal aggregate path, every Item
// write emits an outbox row (aggregate_type = "qa_items"); the qa Debezium
// EventRouter routes it to the `qa_items.events` topic and the service
// self-subscribes (upstreamSubscriptions in microservice.qa.yaml), materializing
// a local `upstream_items` Mongo projection. That projection is what the
// SharedBaseView embeds — 1:1 (Embed "featuredItem") AND 1:N (EmbedMany "items")
// — proving external embeds compose on a shared-base root end to end.
//
// AccountID and CatalogID are NULLABLE plain foreign keys to the two parent
// kinds this fixture proves external embeds on: a SHARED-BASE view (qa_accounts,
// AccountID) and a NORMAL view (qa_catalogs, CatalogID). A list item carries its
// owning parent's id (so the 1:N EmbedMany joins upstream_items.<fk> →
// parent._id); the single "featured" item is created with BOTH nil (it is
// referenced 1:1 by the parent's featured_item_id, not by a reverse FK) — which
// also proves a null-FK item never leaks into any parent's Items array. One
// upstream_items projection feeds both view kinds; an item belongs to at most
// one parent.
type Item struct {
	domain.AggregateRoot
	AccountID *string
	CatalogID *string
	Label     string
}

// Modes advertises the lifecycle verbs the suite drives: Insert to create the
// embed sources, Update to mutate a Label / reassign the FK (move), Delete to
// exercise the delete ripple (the item drops from its parent's list).
func (i *Item) Modes() []domain.EntityMode {
	return []domain.EntityMode{
		domain.ModeDisplay,
		domain.ModeInsert,
		domain.ModeUpdate,
		domain.ModeDelete,
	}
}

// BuildRules: Label is required. AccountID is intentionally unconstrained
// (nullable FK — the featured item carries none).
func (i *Item) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if i.Label == "" {
			r.AddNotification("Label", domain.RequiredFieldNotification{})
		}
	})
}
