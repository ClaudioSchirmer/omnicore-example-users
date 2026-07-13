//go:build qa

package qafixtures

import (
	"context"

	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/read"
	fwdb "github.com/ClaudioSchirmer/omnicore/infra/db/core"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// ProductSchema is the FLAT Go↔column map for the qa_products table: PK + four
// business columns + the managed columns. price_cents is BIGINT (the money
// shape — exact int64 minor units), weight is a fractional column for the
// float64 specs.
func ProductSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[*qadomain.Product]("qa_products").
		PK("id").
		Field("Code", "code").
		Field("Category", "category").
		Field("PriceCents", "price_cents").
		Field("Weight", "weight").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}

// ProductRepository is the flat aggregate-aware repository for Product —
// BaseAggregateRepository gives the 5 writes + New() + FindByID/Scope.
type ProductRepository struct {
	read.BaseAggregateRepository[*qadomain.Product]
}

func NewProductRepository(eng fwdb.RelationalEngine) *ProductRepository {
	r := &ProductRepository{
		BaseAggregateRepository: read.NewBaseAggregateRepository[*qadomain.Product](
			eng,
			func() *qadomain.Product { return &qadomain.Product{} },
		),
	}
	r.WithSchema(ProductSchema())
	return r
}

var _ persistence.ScopedRepository[*qadomain.Product] = (*ProductRepository)(nil)

// ─── Self-provisioning (no migration files) ─────────────────────────────────

// ProvisionProductTable creates the qa_products table if absent,
// dialect-aware, mirroring the ProvisionGadgetTables approach so the QA
// schema stays out of the canonical migration set.
func ProvisionProductTable(ctx context.Context, eng fwdb.RelationalEngine) error {
	q := eng.Querier()
	postgres := eng.Dialect().Placeholder(1) == "$1"

	var products string
	if postgres {
		products = `CREATE TABLE IF NOT EXISTS qa_products (
			id          UUID             PRIMARY KEY,
			code        VARCHAR(64)      NOT NULL,
			category    VARCHAR(128)     NOT NULL,
			price_cents BIGINT           NOT NULL,
			weight      DOUBLE PRECISION NOT NULL,
			deleted_at  TIMESTAMP,
			created_at  TIMESTAMP        NOT NULL DEFAULT NOW(),
			updated_at  TIMESTAMP        NOT NULL DEFAULT NOW()
		)`
	} else {
		products = `CREATE TABLE IF NOT EXISTS qa_products (
			id          BINARY(16)   NOT NULL,
			code        VARCHAR(64)  NOT NULL,
			category    VARCHAR(128) NOT NULL,
			price_cents BIGINT       NOT NULL,
			weight      DOUBLE       NOT NULL,
			deleted_at  DATETIME     NULL,
			created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id)
		)`
	}
	return q.Exec(ctx, products)
}
