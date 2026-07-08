//go:build qa

package qafixtures

import (
	"context"

	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/read"
	fwdb "github.com/ClaudioSchirmer/omnicore/infra/db/core"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// ItemSchema is the FLAT Go↔column map for the qa_items table. account_id is a
// nullable plain FK to the account base id; there is no aggregate child, no
// shared base — the Item is a write-side stranger whose ONLY read-side presence
// is the `upstream_items` projection the shared-base view embeds.
func ItemSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[*qadomain.Item]("qa_items").
		PK("id").
		Field("AccountID", "account_id").
		Field("CatalogID", "catalog_id").
		Field("Label", "label").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}

// UpstreamItemSchema is the type-less EXTERNAL schema describing the
// `upstream_items` Mongo collection — the local projection the service
// materializes from its OWN qa_items CDC topic (upstreamSubscriptions in
// microservice.qa.yaml, filter [id, account_id, label]). PK("id") is the
// document key (the UpstreamSubscriber upserts each doc under _id = the item's
// aggregate id). It is the embed source of BOTH the 1:1 Embed ("featuredItem",
// joined on the account's featured_item_id → this _id) and the 1:N EmbedMany
// ("items", joined on this account_id → the account _id) declared on
// AccountView — so a fresh instance is handed to each embed (the EmbedMany
// variant additionally declares .FK("account_id") on its own copy).
func UpstreamItemSchema() *fwdb.TableSchema {
	return fwdb.NewExternalSchema("upstream_items").
		PK("id").
		Field("Label", "label").
		Field("AccountID", "account_id").
		Field("CatalogID", "catalog_id")
}

// ItemRepository is the flat aggregate-aware repository for Item — the same
// canonical BaseAggregateRepository shape the Gadget fixtures use.
type ItemRepository struct {
	read.BaseAggregateRepository[*qadomain.Item]
}

func NewItemRepository(eng fwdb.RelationalEngine) *ItemRepository {
	r := &ItemRepository{
		BaseAggregateRepository: read.NewBaseAggregateRepository[*qadomain.Item](
			eng,
			func() *qadomain.Item { return &qadomain.Item{} },
		),
	}
	r.WithSchema(ItemSchema())
	return r
}

var _ persistence.ScopedRepository[*qadomain.Item] = (*ItemRepository)(nil)

// ProvisionItemTable creates the `qa_items` table if it does not exist,
// dialect-aware, mirroring the other QA self-provisioners (idempotent, engine
// side-channel, no migration files).
func ProvisionItemTable(ctx context.Context, eng fwdb.RelationalEngine) error {
	q := eng.Querier()
	postgres := eng.Dialect().Placeholder(1) == "$1"

	var items string
	if postgres {
		items = `CREATE TABLE IF NOT EXISTS qa_items (
			id          UUID         PRIMARY KEY,
			account_id  VARCHAR(36),
			catalog_id  VARCHAR(36),
			label       VARCHAR(255) NOT NULL,
			deleted_at  TIMESTAMP,
			created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
	} else {
		items = `CREATE TABLE IF NOT EXISTS qa_items (
			id          BINARY(16)   NOT NULL,
			account_id  VARCHAR(36)  NULL,
			catalog_id  VARCHAR(36)  NULL,
			label       VARCHAR(255) NOT NULL,
			deleted_at  DATETIME     NULL,
			created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id)
		)`
	}
	return q.Exec(ctx, items)
}
