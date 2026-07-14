//go:build qa

package qafixtures

import (
	"context"

	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/read"
	fwdb "github.com/ClaudioSchirmer/omnicore/infra/db/core"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// accountBase is the schema-only shared IDENTITY (core.NewSharedBase) the
// AccountHolder role specializes — the qa analog of personBase(). id is
// UUIDv5(account_ref); the base owns no children (the persons fixture covers
// base-children), keeping this fixture focused on the ONE thing it adds: the
// external embeds on a shared-base view. featured_item_id is the nullable 1:1
// embed FK. OrphanPolicy hard-deletes the identity when its last role goes.
func accountBase() *fwdb.TableSchema {
	return fwdb.NewSharedBase("qa_accounts").
		PK("id").
		Field("AccountRef", "account_ref").
		Field("DisplayName", "display_name").
		Field("FeaturedItemID", "featured_item_id").
		NaturalKey("account_ref").
		SoftDelete("deleted_at").
		OrphanPolicy(fwdb.DeleteWhenUnreferenced)
}

// AccountHolderSchema is the type-anchored ROLE schema linking back to the base
// (shared-PK model: qa_account_holders.id == qa_accounts.id). It declares only
// the role-private HolderName; the base fields come from accountBase().
func AccountHolderSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[*qadomain.AccountHolder]("qa_account_holders").
		PK("id").
		SharedBase(accountBase(), "id").
		Field("HolderName", "holder_name").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}

// AccountView is the SharedBaseView PROOF: a base-rooted view (base fields flat
// + the AccountHolder role sub-document) that ALSO composes two EXTERNAL embeds
// over the SAME `upstream_items` projection —
//
//   - Embed "featuredItem" (1:1): the base holds the FK (featured_item_id →
//     upstream_items._id). A single sub-document, null when unset/unresolved.
//   - EmbedMany "items" (1:N): the leg holds the FK (upstream_items.account_id →
//     the account base _id). An array, empty when none.
//
// Both are declared with a FRESH UpstreamItemSchema() instance (the EmbedMany
// copy additionally carries .FK("account_id"), the 1:N child join column). The
// composer's applyEmbeds runs identically on a base-rooted row and a regular
// view row, and buildViewIndex registers these embeds for recompose-ripple, so
// an upstream_items change recomposes this shared-base document — proving the
// end-to-end path the docs claim for SharedBaseView + Embed/EmbedMany.
func AccountView() *query.ViewDefinition {
	featured := query.FromSchema(UpstreamItemSchema()).
		FK("featured_item_id").
		As("FeaturedItem")
	items := query.FromSchema(UpstreamItemSchema().FK("account_id")).
		As("Items")
	return query.SharedBaseView(accountBase(), "qa_accounts_view").
		Role(AccountHolderSchema()).
		Embed("featuredItem", featured).
		EmbedMany("items", items).
		Version(1).
		Indexes(
			query.Index("account_ref"),
			// §8.1 covering index on the 1:1 Embed's parent FK column — the
			// ripple's reverse scan (FindIDsByField) consults it on every
			// upstream_items event. The 1:N EmbedMany needs NO index here: its
			// ripple resolves the parent by the child's FK value → the parent _id
			// (always indexed), never a reverse scan of this view.
			query.Index("featured_item_id"),
		)
}

// AccountHolderRepository is the shared-base ROLE repository (the marriage the
// SharedBaseInsertCommandHandler requires): SharedBaseRoleRepository over the
// role schema, which the handler upserts by natural key.
type AccountHolderRepository struct {
	read.SharedBaseRoleRepository[*qadomain.AccountHolder]
}

func NewAccountHolderRepository(eng fwdb.RelationalEngine) *AccountHolderRepository {
	r := &AccountHolderRepository{
		SharedBaseRoleRepository: read.NewSharedBaseRoleRepository[*qadomain.AccountHolder](
			eng,
			func() *qadomain.AccountHolder { return &qadomain.AccountHolder{} },
		),
	}
	r.WithSchema(AccountHolderSchema())
	return r
}

var _ persistence.ScopedRepository[*qadomain.AccountHolder] = (*AccountHolderRepository)(nil)

// ProvisionAccountTables creates the `qa_accounts` base + `qa_account_holders`
// role tables if absent, dialect-aware (idempotent, engine side-channel, no
// migration files) — mirroring the persons/employees DDL in miniature.
func ProvisionAccountTables(ctx context.Context, eng fwdb.RelationalEngine) error {
	postgres := eng.Dialect().Placeholder(1) == "$1"

	var base, role string
	if postgres {
		base = `CREATE TABLE IF NOT EXISTS qa_accounts (
			id                UUID         PRIMARY KEY,
			account_ref       VARCHAR(64)  NOT NULL,
			display_name      VARCHAR(255) NOT NULL,
			featured_item_id  VARCHAR(36),
			deleted_at        TIMESTAMP,
			created_at        TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at        TIMESTAMP    NOT NULL DEFAULT NOW(),
			CONSTRAINT qa_accounts_account_ref_key UNIQUE (account_ref)
		)`
		role = `CREATE TABLE IF NOT EXISTS qa_account_holders (
			id           UUID         PRIMARY KEY REFERENCES qa_accounts (id) ON DELETE CASCADE,
			holder_name  VARCHAR(255) NOT NULL,
			deleted_at   TIMESTAMP,
			created_at   TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at   TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
	} else {
		base = `CREATE TABLE IF NOT EXISTS qa_accounts (
			id                BINARY(16)   NOT NULL,
			account_ref       VARCHAR(64)  NOT NULL,
			display_name      VARCHAR(255) NOT NULL,
			featured_item_id  VARCHAR(36)  NULL,
			deleted_at        DATETIME     NULL,
			created_at        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id),
			UNIQUE KEY qa_accounts_account_ref_key (account_ref)
		)`
		role = `CREATE TABLE IF NOT EXISTS qa_account_holders (
			id           BINARY(16)   NOT NULL,
			holder_name  VARCHAR(255) NOT NULL,
			deleted_at   DATETIME     NULL,
			created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id),
			CONSTRAINT fk_qa_account_holders_account FOREIGN KEY (id) REFERENCES qa_accounts (id) ON DELETE CASCADE
		)`
	}

	return qaExecDDL(ctx, eng, base, role)
}
