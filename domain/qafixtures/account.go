//go:build qa

package qafixtures

import "github.com/ClaudioSchirmer/omnicore/domain"

// AccountHolder is the ROLE of a shared-base identity — the qa counterpart of
// the canonical Employee-over-Person pair, built for ONE purpose the persons
// fixture never exercises: proving that a query.SharedBaseView also composes
// EXTERNAL embeds (Embed AND EmbedMany), not only roles.
//
// The shared identity is the `qa_accounts` base (schema-only, declared via
// core.NewSharedBase in infra); this struct is its single role, carrying the
// base's own fields (AccountRef the natural key, DisplayName, FeaturedItemID)
// flat alongside the role-private HolderName — exactly as Employee carries the
// Person fields (Name/Email/Document) flat next to EmployeeNumber. The base id
// is UUIDv5(AccountRef); a re-POST of the same AccountRef upserts the identity.
//
// FeaturedItemID is a NULLABLE base column holding a 1:1 foreign key to an
// `upstream_items` document _id — the join the SharedBaseView's Embed
// ("featuredItem") resolves. The 1:N EmbedMany ("items") joins the other way
// (upstream_items.account_id → this base id), so no column is needed here for
// it. Both embed sources are the SAME external projection; see AccountView.
type AccountHolder struct {
	domain.AggregateRoot
	AccountRef     string  // base natural key → qa_accounts.account_ref
	DisplayName    string  // base field   → qa_accounts.display_name
	FeaturedItemID *string // base field   → qa_accounts.featured_item_id (1:1 embed FK)
	HolderName     string  // role-private → qa_account_holders.holder_name
}

// Modes advertises the verbs the suite drives: Insert (create/upsert the
// identity + role) and Display (read the composed shared-base document).
func (a *AccountHolder) Modes() []domain.EntityMode {
	return []domain.EntityMode{
		domain.ModeDisplay,
		domain.ModeInsert,
		domain.ModeUpdate,
	}
}

// BuildRules: the natural key + display name (base) and the holder name (role)
// are required. All notifications are framework built-ins.
func (a *AccountHolder) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if a.AccountRef == "" {
			r.AddNotification("AccountRef", domain.RequiredFieldNotification{})
		}
		if a.DisplayName == "" {
			r.AddNotification("DisplayName", domain.RequiredFieldNotification{})
		}
		if a.HolderName == "" {
			r.AddNotification("HolderName", domain.RequiredFieldNotification{})
		}
	})
}
