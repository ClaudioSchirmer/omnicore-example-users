//go:build qa

package qafixtures

import (
	"time"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
)

// The wire shape of the composite-value-object family. Note what it is NOT:
// there is no nested "salary" or "trial" object. The parts are FLAT fields,
// named exactly as the schema exposed them (.As(...)), because the read side
// never learns a composite exists — that transparency is the design, and this
// DTO is where it becomes visible.

type InsertContractRequest struct {
	Code           string     `json:"code" validate:"required" example:"CT-9911"`
	SalaryAmount   int64      `json:"salaryAmount" example:"850000"`
	SalaryCurrency string     `json:"salaryCurrency" validate:"required" example:"BRL"`
	TrialFrom      *time.Time `json:"trialFrom"`
	TrialTo        *time.Time `json:"trialTo"`
}

func (r InsertContractRequest) ToCommand() *appqa.InsertContractCommand {
	return &appqa.InsertContractCommand{
		Code:           r.Code,
		SalaryAmount:   r.SalaryAmount,
		SalaryCurrency: r.SalaryCurrency,
		TrialFrom:      r.TrialFrom,
		TrialTo:        r.TrialTo,
	}
}

type UpdateContractRequest struct {
	Code           string     `json:"code" validate:"required" example:"CT-9911"`
	SalaryAmount   int64      `json:"salaryAmount" example:"920000"`
	SalaryCurrency string     `json:"salaryCurrency" validate:"required" example:"BRL"`
	TrialFrom      *time.Time `json:"trialFrom"`
	TrialTo        *time.Time `json:"trialTo"`
}

func (r UpdateContractRequest) ToCommand() *appqa.UpdateContractCommand {
	return &appqa.UpdateContractCommand{
		Code:           r.Code,
		SalaryAmount:   r.SalaryAmount,
		SalaryCurrency: r.SalaryCurrency,
		TrialFrom:      r.TrialFrom,
		TrialTo:        r.TrialTo,
	}
}

type ContractWriteResponse struct {
	ID             string     `json:"id"`
	Code           string     `json:"code"`
	SalaryAmount   int64      `json:"salaryAmount"`
	SalaryCurrency string     `json:"salaryCurrency"`
	TrialFrom      *time.Time `json:"trialFrom"`
	TrialTo        *time.Time `json:"trialTo"`
}

func (ContractWriteResponse) FromResult(r appqa.ContractResult) ContractWriteResponse {
	return ContractWriteResponse{
		ID:             r.ID.Value(),
		Code:           r.Code,
		SalaryAmount:   r.SalaryAmount,
		SalaryCurrency: r.SalaryCurrency,
		TrialFrom:      r.TrialFrom,
		TrialTo:        r.TrialTo,
	}
}

// FindContractsRequest declares a filter leaf on a part of EACH composite —
// which is only possible because a part is an ordinary logical field by the
// time the read side sees it.
type FindContractsRequest struct {
	Code           *string `query:"code" filter:"eq,contains"`
	SalaryAmount   *int64  `query:"salaryAmount" filter:"eq,gte,lte"`
	SalaryCurrency *string `query:"salaryCurrency" filter:"eq"`
	TrialFrom      *string `query:"trialFrom" filter:"gte,lte"`

	First           *int64  `query:"first"`
	Last            *int64  `query:"last"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	OrderBy         *string `query:"orderBy"`
	Fields          *string `query:"fields"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

func (r FindContractsRequest) ToQuery(criteria fwqueries.ReadCriteria) *appqa.FindContractsQuery {
	return &appqa.FindContractsQuery{Criteria: criteria}
}

// FindContractsResponse mirrors the storage: flat parts, no nesting. The
// currency is typed as the value object so the read side converges an
// out-of-set stored value to the Unknown sentinel, exactly as a root enum
// value-object field does.
type FindContractsResponse struct {
	ID             *string    `json:"id,omitempty"`
	Code           *string    `json:"code,omitempty"`
	SalaryAmount   *int64     `json:"salaryAmount,omitempty"`
	SalaryCurrency *string    `json:"salaryCurrency,omitempty"`
	TrialFrom      *time.Time `json:"trialFrom,omitempty"`
	TrialTo        *time.Time `json:"trialTo,omitempty"`
}

type FindContractByIDRequest struct {
	IncludeArchived *bool `query:"includeArchived"`
}

func (r FindContractByIDRequest) ToQuery() *appqa.FindContractByIDQuery {
	q := &appqa.FindContractByIDQuery{}
	if r.IncludeArchived != nil {
		q.IncludeArchived = *r.IncludeArchived
	}
	return q
}
