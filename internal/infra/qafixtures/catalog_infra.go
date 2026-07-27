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

// CatalogSchema is the FLAT Go↔column map for the qa_catalogs table (a normal
// aggregate root — no shared base). featured_item_id is the nullable 1:1 embed
// FK into upstream_items.
func CatalogSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[*qadomain.Catalog]("qa_catalogs").
		PK("id").
		Revision("revision").
		Field("Name", "name").
		Field("FeaturedItemID", "featured_item_id").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at").
		Child(CatalogLineSchema())
}

// CatalogLineSchema is the native aggregate child of Catalog (qa_catalog_lines):
// value-typed AVO, FK catalog_id back to the root, item_id the FK the
// qa_catalog_view enriches via EmbedInChild (→ upstream_items._id).
func CatalogLineSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[qadomain.CatalogLine]("qa_catalog_lines").
		PK("id").
		FK("catalog_id").
		Field("ItemID", "item_id").
		Field("Note", "note").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}

// CatalogView is the NORMAL-view proof (query.View, not SharedBaseView) that the
// SAME external Embed + EmbedMany compose on a regular aggregate root:
//
//   - Embed "featuredItem" (1:1): the catalog holds the FK (featured_item_id →
//     upstream_items._id).
//   - EmbedMany "items" (1:N): the leg holds the FK (upstream_items.catalog_id →
//     the catalog _id).
//
// It embeds the exact same `upstream_items` projection the shared-base
// AccountView does, but joins the 1:N side on catalog_id — so one collection
// feeds both view kinds and an item belongs to at most one parent.
func CatalogView() *query.ViewDefinition {
	featured := query.FromSchema(UpstreamItemSchema()).
		FK("featured_item_id").
		As("FeaturedItem")
	items := query.FromSchema(UpstreamItemSchema().FK("catalog_id")).
		As("Items")
	// EmbedInChild: enrich each native CatalogLine element with its upstream item
	// (1:1, keyed by the line's own item_id → upstream_items._id).
	lineItem := query.FromSchema(UpstreamItemSchema()).
		FK("item_id").
		As("Item")
	return query.View("qa_catalog_view").
		Version(1).
		Schema(CatalogSchema()).
		Embed("featuredItem", featured).
		EmbedMany("items", items).
		EmbedInChild(CatalogLineSchema(), "item", lineItem).
		Indexes(
			// §8.1 covering index on the 1:1 Embed's parent FK column; the 1:N
			// EmbedMany resolves by the child's catalog_id → catalog _id.
			query.Index("featured_item_id"),
			// Covering multikey index for the EmbedInChild ripple's reverse scan
			// ("<childSegment>.<fk>" = CatalogLines.item_id) — mandatory at boot.
			query.Index("CatalogLines.item_id"),
		)
}

// CatalogRepository is the flat aggregate-aware repository for Catalog.
type CatalogRepository struct {
	read.BaseAggregateRepository[*qadomain.Catalog]
}

func NewCatalogRepository(eng fwdb.RelationalEngine) *CatalogRepository {
	r := &CatalogRepository{
		BaseAggregateRepository: read.NewBaseAggregateRepository[*qadomain.Catalog](
			eng,
			func() *qadomain.Catalog { return &qadomain.Catalog{} },
		),
	}
	r.WithSchema(CatalogSchema())
	return r
}

var _ persistence.ScopedRepository[*qadomain.Catalog] = (*CatalogRepository)(nil)

// ProvisionCatalogTable creates the `qa_catalogs` table if absent, dialect-aware
// (idempotent, engine side-channel, no migration files).
func ProvisionCatalogTable(ctx context.Context, eng fwdb.RelationalEngine) error {
	postgres := eng.Dialect().Placeholder(1) == "$1"

	var catalogs string
	if postgres {
		catalogs = `CREATE TABLE IF NOT EXISTS qa_catalogs (
			id                UUID         PRIMARY KEY,
			revision          BIGINT       NOT NULL DEFAULT 0,
			name              VARCHAR(255) NOT NULL,
			featured_item_id  VARCHAR(36),
			deleted_at        TIMESTAMP,
			created_at        TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at        TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
	} else {
		catalogs = `CREATE TABLE IF NOT EXISTS qa_catalogs (
			id                BINARY(16)   NOT NULL,
			revision          BIGINT       NOT NULL DEFAULT 0,
			name              VARCHAR(255) NOT NULL,
			featured_item_id  VARCHAR(36)  NULL,
			deleted_at        DATETIME     NULL,
			created_at        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id)
		)`
	}
	if err := qaExecDDL(ctx, eng, catalogs); err != nil {
		return err
	}

	var lines string
	if postgres {
		lines = `CREATE TABLE IF NOT EXISTS qa_catalog_lines (
			id          UUID         PRIMARY KEY,
			catalog_id  UUID         NOT NULL REFERENCES qa_catalogs(id) ON DELETE CASCADE,
			item_id     VARCHAR(36),
			note        VARCHAR(255) NOT NULL,
			deleted_at  TIMESTAMP,
			created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
	} else {
		lines = `CREATE TABLE IF NOT EXISTS qa_catalog_lines (
			id          BINARY(16)   NOT NULL,
			catalog_id  BINARY(16)   NOT NULL,
			item_id     VARCHAR(36)  NULL,
			note        VARCHAR(255) NOT NULL,
			deleted_at  DATETIME     NULL,
			created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id)
		)`
	}
	return qaExecDDL(ctx, eng, lines)
}
