//go:build qa

// Relational + read-side wiring for the QA-only Tenant aggregate — the fixture
// behind the `old_state_archive` suite. Two tables (root + native child), a
// Mongo view, and self-provisioning DDL (no migration file), all gated behind
// the `qa` build tag.
package qafixtures

import (
	"context"

	"github.com/ClaudioSchirmer/omnicore/infra/db/command/read"
	fwdb "github.com/ClaudioSchirmer/omnicore/infra/db/core"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// TenantSchema maps the aggregate across its two tables. old_status_seen and
// old_plan_seen are ordinary columns — the framework knows nothing about their
// meaning; they are persisted because BuildRules writes them, which is exactly
// what makes them usable as an external probe of domain.Old. They are NOT NULL
// with no default: the domain always writes a non-empty value, and the framework
// writes both columns on every write anyway — never as the empty string, which
// Oracle would store as NULL (see qadomain.TenantNoOldState).
func TenantSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[*qadomain.Tenant]("qa_tenants").
		ID("id").
		Revision("revision").
		Field("Code", "code").
		Field("Status", "status").
		Field("Plan", "plan_code").
		Field("OldStatusSeen", "old_status_seen").
		Field("OldPlanSeen", "old_plan_seen").
		DeletedAt("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at").
		Child(TenantSeatSchema())
}

// TenantSeatSchema is the native child: ParentID tenant_id back to the root.
// It carries its own DeletedAt, which is what the archive cascade moves — and
// what the suite checks stays the ONLY thing that moved.
func TenantSeatSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[qadomain.TenantSeat]("qa_tenant_seats").
		ID("id").
		ParentID("tenant_id").
		Field("Label", "label").
		Field("Seat", "seat").
		DeletedAt("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}

// TenantView is the Mongo projection: the flat tenant plus its TenantSeats
// child array. The suite reads it to prove the relational row and the
// projected document tell the SAME story after an archive — the divergence
// that started this whole line of work.
func TenantView() *query.ViewDefinition {
	return query.View("qa_tenants_view").
		Version(1).
		Schema(TenantSchema()).
		Indexes(query.Index("code"))
}

// TenantRepository is the aggregate-aware repository for Tenant.
type TenantRepository struct {
	read.BaseAggregateRepository[*qadomain.Tenant]
}

func NewTenantRepository(eng fwdb.RelationalEngine) *TenantRepository {
	r := &TenantRepository{
		BaseAggregateRepository: read.NewBaseAggregateRepository[*qadomain.Tenant](
			eng, func() *qadomain.Tenant { return &qadomain.Tenant{} },
		),
	}
	r.WithSchema(TenantSchema())
	return r
}

// ProvisionTenantTables creates the two Tenant tables if absent, dialect-aware
// via qaExecDDL (postgres + mysql hand-written, sqlserver + oracle derived).
func ProvisionTenantTables(ctx context.Context, eng fwdb.RelationalEngine) error {
	postgres := eng.Dialect().Placeholder(1) == "$1"

	var tenants, seats string
	if postgres {
		tenants = `CREATE TABLE IF NOT EXISTS qa_tenants (
			id               UUID         PRIMARY KEY,
			revision         BIGINT       NOT NULL DEFAULT 0,
			code             VARCHAR(64)  NOT NULL,
			status           VARCHAR(32)  NOT NULL,
			plan_code        VARCHAR(64)  NOT NULL,
			old_status_seen  VARCHAR(32)  NOT NULL,
			old_plan_seen    VARCHAR(64)  NOT NULL,
			deleted_at       TIMESTAMP,
			created_at       TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at       TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
		seats = `CREATE TABLE IF NOT EXISTS qa_tenant_seats (
			id          UUID         PRIMARY KEY,
			tenant_id   UUID         NOT NULL REFERENCES qa_tenants (id) ON DELETE CASCADE,
			label       VARCHAR(255) NOT NULL,
			seat        INT          NOT NULL DEFAULT 0,
			deleted_at  TIMESTAMP,
			created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
	} else {
		tenants = `CREATE TABLE IF NOT EXISTS qa_tenants (
			id               BINARY(16)   NOT NULL,
			revision         BIGINT       NOT NULL DEFAULT 0,
			code             VARCHAR(64)  NOT NULL,
			status           VARCHAR(32)  NOT NULL,
			plan_code        VARCHAR(64)  NOT NULL,
			old_status_seen  VARCHAR(32)  NOT NULL,
			old_plan_seen    VARCHAR(64)  NOT NULL,
			deleted_at       DATETIME     NULL,
			created_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id)
		)`
		seats = `CREATE TABLE IF NOT EXISTS qa_tenant_seats (
			id          BINARY(16)   NOT NULL,
			tenant_id   BINARY(16)   NOT NULL,
			label       VARCHAR(255) NOT NULL,
			seat        INT          NOT NULL DEFAULT 0,
			deleted_at  DATETIME     NULL,
			created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id),
			FOREIGN KEY (tenant_id) REFERENCES qa_tenants (id) ON DELETE CASCADE
		)`
	}

	return qaExecDDL(ctx, eng, tenants, seats)
}
