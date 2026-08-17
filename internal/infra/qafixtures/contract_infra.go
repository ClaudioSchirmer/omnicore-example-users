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

// The COMPOSITE VALUE OBJECT family's infrastructure — and the ONLY place that
// knows a composite is stored across several columns. The domain declares two
// plain structs that own their rules; here they are decomposed.
//
// Both read backings are declared over the SAME root, because both must work
// and they take different code paths to the same document: the Mongo projection
// (composer → CDC → SyncEngine) and the RelationalSource twin (served straight
// from the SoR through the repository's own loader, which is the path that
// consumes SharedBaseScanPlan/ScanPlan and therefore the FieldPath change).

// ContractSchema decomposes both value objects. Note the aliasing: Money is a
// GENERIC value object, so the default exposed names (Amount, Currency) would
// be meaningless on the wire and would collide the day this entity carries a
// second Money-shaped concept. Period is aliased for the same reason.
func ContractSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[*qadomain.Contract]("qa_contracts").
		ID("id").
		Revision("revision").
		Field("Code", "code").
		Composite(fwdb.NewCompositeValueObject[qadomain.Money]().
			Field("Amount", "salary_amount").As("SalaryAmount").
			Field("Currency", "salary_currency").As("SalaryCurrency")).
		Composite(fwdb.NewCompositeValueObject[qadomain.Period]().
			Field("From", "trial_from").As("TrialFrom").
			Field("To", "trial_to").As("TrialTo")).
		DeletedAt("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}

type ContractRepository struct {
	read.BaseAggregateRepository[*qadomain.Contract]
}

func NewContractRepository(eng fwdb.RelationalEngine) *ContractRepository {
	r := &ContractRepository{
		BaseAggregateRepository: read.NewBaseAggregateRepository[*qadomain.Contract](
			eng, func() *qadomain.Contract { return &qadomain.Contract{} },
		),
	}
	r.WithSchema(ContractSchema())
	return r
}

var _ persistence.ScopedRepository[*qadomain.Contract] = (*ContractRepository)(nil)

// ContractsView is the Mongo-projected read side. The document carries the
// parts as FLAT PHYSICAL COLUMNS (salary_amount, trial_from, …) exactly as a
// hand-flattened field would — the projection never learns a composite exists,
// which is what the suite asserts directly against Mongo.
func ContractsView() *query.ViewDefinition {
	return query.View("qa_contracts_view").
		Version(1).
		Schema(ContractSchema()).
		Indexes(query.Index("code"), query.Index("salary_amount"))
}

// ContractsRelView is the RelationalSource twin over the SAME root, served
// through the repository's own loader (one loader, shared with the repo). It is
// not a bonus surface: the relational read path resolves every column through
// the scan plan, so it is the second — and structurally different — proof that
// decomposition round-trips.
func ContractsRelView(loader query.RelationalReader) *query.ViewDefinition {
	return query.View("qa_contracts_rel").
		Version(1).
		Schema(ContractSchema()).
		RelationalSource(loader)
}

// ProvisionContractTables creates qa_contracts if absent. Postgres and MySQL
// are hand-written (the always-on lanes); SQL Server and Oracle are derived
// mechanically by qaExecDDL, the house pattern for QA scaffolding.
//
// EVERY part column of the OPTIONAL composite is NULL-able, and that is a
// requirement rather than a style choice: writing a nil *Period writes NULL to
// all of them, and the read reconstructs nil only when all of them are NULL.
// The mandatory composite's parts are NOT NULL — each part follows its own Go
// type, exactly as a scalar value-object field does.
func ProvisionContractTables(ctx context.Context, eng fwdb.RelationalEngine) error {
	postgres := eng.Dialect().Placeholder(1) == "$1"

	var contracts string
	if postgres {
		contracts = `CREATE TABLE IF NOT EXISTS qa_contracts (
			id               UUID         PRIMARY KEY,
			revision         BIGINT       NOT NULL DEFAULT 0,
			code             VARCHAR(64)  NOT NULL,
			salary_amount    BIGINT       NOT NULL,
			salary_currency  VARCHAR(3)   NOT NULL,
			trial_from       TIMESTAMP,
			trial_to         TIMESTAMP,
			deleted_at       TIMESTAMP,
			created_at       TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at       TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
	} else {
		contracts = `CREATE TABLE IF NOT EXISTS qa_contracts (
			id               BINARY(16)   NOT NULL,
			revision         BIGINT       NOT NULL DEFAULT 0,
			code             VARCHAR(64)  NOT NULL,
			salary_amount    BIGINT       NOT NULL,
			salary_currency  VARCHAR(3)   NOT NULL,
			trial_from       DATETIME     NULL,
			trial_to         DATETIME     NULL,
			deleted_at       DATETIME     NULL,
			created_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id)
		)`
	}
	return qaExecDDL(ctx, eng, contracts)
}
