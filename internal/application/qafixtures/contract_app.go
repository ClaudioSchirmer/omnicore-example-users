//go:build qa

package qafixtures

import (
	"time"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// Commands + queries for the composite-value-object family. The command owns
// the input shape, and it is the only place the wire's flat fields are folded
// back into the two value objects — the framework decomposes for storage, the
// application composes from the request. Neither knows about the other.

type ContractResult struct {
	ID             domain.ID
	Code           string
	SalaryAmount   int64
	SalaryCurrency string
	TrialFrom      *time.Time
	TrialTo        *time.Time
}

func contractResult(c *qadomain.Contract) ContractResult {
	out := ContractResult{
		ID:             *c.GetID(),
		Code:           string(c.Code),
		SalaryAmount:   c.Salary.Amount,
		SalaryCurrency: string(c.Salary.Currency),
	}
	if c.Trial != nil {
		from := c.Trial.From
		out.TrialFrom = &from
		out.TrialTo = c.Trial.To
	}
	return out
}

// buildTrial folds the two wire fields back into the OPTIONAL composite: absent
// start ⇒ absent value object, which is what writes NULL to every part column.
func buildTrial(from, to *time.Time) *qadomain.Period {
	if from == nil {
		return nil
	}
	return &qadomain.Period{From: *from, To: to}
}

type InsertContractCommand struct {
	pipeline.CommandWithBodyBase
	Code           string
	SalaryAmount   int64
	SalaryCurrency string
	TrialFrom      *time.Time
	TrialTo        *time.Time
}

func (c *InsertContractCommand) ToEntity(_ *configuration.AppContext) (*qadomain.Contract, error) {
	return &qadomain.Contract{
		Code: qadomain.ContractCode(c.Code),
		Salary: qadomain.Money{
			Amount: c.SalaryAmount,
			// The wire value converges through membership: anything outside the
			// declared set becomes the Unknown sentinel, which the enum's own
			// validation then rejects.
			Currency: domain.EnumByValue[qadomain.Currency](c.SalaryCurrency),
		},
		Trial: buildTrial(c.TrialFrom, c.TrialTo),
	}, nil
}

func (c *InsertContractCommand) FromEntity(_ *configuration.AppContext, e *qadomain.Contract) (ContractResult, error) {
	return contractResult(e), nil
}

var _ pipeline.InsertCommand[*qadomain.Contract, ContractResult] = (*InsertContractCommand)(nil)

type UpdateContractCommand struct {
	pipeline.CommandWithBodyIDBase
	Code           string
	SalaryAmount   int64
	SalaryCurrency string
	TrialFrom      *time.Time
	TrialTo        *time.Time
}

func (c *UpdateContractCommand) ApplyTo(_ *configuration.AppContext, e *qadomain.Contract) error {
	e.Code = qadomain.ContractCode(c.Code)
	e.Salary = qadomain.Money{
		Amount:   c.SalaryAmount,
		Currency: domain.EnumByValue[qadomain.Currency](c.SalaryCurrency),
	}
	e.Trial = buildTrial(c.TrialFrom, c.TrialTo)
	return nil
}

func (c *UpdateContractCommand) FromEntity(_ *configuration.AppContext, e *qadomain.Contract) (ContractResult, error) {
	return contractResult(e), nil
}

type ArchiveContractCommand struct{ pipeline.CommandByIDBase }

func (*ArchiveContractCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.Contract) error {
	return nil
}
func (*ArchiveContractCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.Contract) (fwresults.None, error) {
	return fwresults.None{}, nil
}

type UnarchiveContractCommand struct{ pipeline.CommandByIDBase }

func (*UnarchiveContractCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.Contract) error {
	return nil
}
func (*UnarchiveContractCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.Contract) (fwresults.None, error) {
	return fwresults.None{}, nil
}

type DeleteContractCommand struct{ pipeline.CommandByIDBase }

func (*DeleteContractCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.Contract) error {
	return nil
}
func (*DeleteContractCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.Contract) (fwresults.None, error) {
	return fwresults.None{}, nil
}

// ─── queries ─────────────────────────────────────────────────────────────────

type FindContractsQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindContractsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}

func (q FindContractsQuery) FromQueryResult(_ *configuration.AppContext, r FindContractsResult) (FindContractsResult, error) {
	return r, nil
}

// FindContractsResult mirrors the storage: FLAT parts, no nested composite.
// The read side never learns a composite value object exists — that
// transparency is the design, and this Result is where it becomes visible.
// Pointers throughout because the endpoint opts into `?fields=`. Both read
// backings (the Mongo projection and the RelationalSource twin) fill the same
// shape, and the by-id read serves the identical document — so both queries
// share this Result.
type FindContractsResult struct {
	ID             *string
	Code           *string
	SalaryAmount   *int64
	SalaryCurrency *string
	TrialFrom      *time.Time
	TrialTo        *time.Time
}

type FindContractByIDQuery struct {
	fwqueries.QueryByIDBase
	Criteria fwqueries.ReadCriteria
}

func (q FindContractByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}
func (q FindContractByIDQuery) FromQueryResult(_ *configuration.AppContext, r FindContractsResult) (FindContractsResult, error) {
	return r, nil
}
func (q FindContractByIDQuery) ContextName() string { return "Contract" }
