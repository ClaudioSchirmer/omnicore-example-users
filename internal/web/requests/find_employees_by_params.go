package requests

import (
	"time"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// FindEmployeesByParamsRequest declares the wire allowlist for
// GET /employees via struct tags, mirroring FindUsersByParamsRequest.
// The three child collections surface as embed groups — struct-typed fields
// carrying a query prefix — so ?dependents.relationship=daughter and
// ?jobHistories.department=Platform resolve to Go field paths the reader
// translates to the physical Mongo paths via the view's schemas.
type FindEmployeesByParamsRequest struct {
	Name           *string `query:"name"      filter:"eq,startswith,icontains,istartswith"`
	Email          *string `query:"email"     filter:"eq,in,ieq"`
	Document       *string `query:"document"  filter:"eq,in,startswith"`
	EmployeeNumber *string `query:"employeeNumber" filter:"eq,in,startswith"`
	Bank           *string `query:"bank"     filter:"eq,in"`

	Addresses    AddressFilterParams    `query:"addresses"`
	Dependents   DependentFilterParams  `query:"dependents"`
	JobHistories JobHistoryFilterParams `query:"jobHistories"`

	Limit           *int64  `query:"limit"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	Sort            *string `query:"sort"`
	Fields          *string `query:"fields"`
	Search          *string `query:"search"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

// DependentFilterParams is the embed-group filter vocabulary for the
// dependents child — includes a sibling-backed leaf (healthPlanProvider) so the QA
// suite can filter by a child-sibling field.
type DependentFilterParams struct {
	Name               *string `query:"name"       filter:"eq,istartswith,icontains"`
	Relationship       *string `query:"relationship" filter:"eq,in"`
	HealthPlanProvider *string `query:"healthPlanProvider"  filter:"eq,in"`
}

// JobHistoryFilterParams is the embed-group filter vocabulary for the
// jobHistories child.
type JobHistoryFilterParams struct {
	JobTitle   *string `query:"jobTitle"        filter:"eq,istartswith,icontains"`
	Department *string `query:"department" filter:"eq,in"`
}

func (r FindEmployeesByParamsRequest) ToQuery(criteria fwqueries.ReadCriteria) *queries.FindEmployeeByParamsQuery {
	return &queries.FindEmployeeByParamsQuery{Criteria: criteria}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FindEmployeesByParamsResponse is the wire projection of one Employee
// view document in the GET /employees list. Every field is a pointer (or
// slice) with omitempty — the sparse-render contract behind `?fields=`.
// The shared Person fields and the bank sibling render FLAT at the root,
// exactly as the composer stores them.
type FindEmployeesByParamsResponse struct {
	ID             *string `json:"id,omitempty"        example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name           *string `json:"name,omitempty"      example:"Alice Pereira"`
	Email          *string `json:"email,omitempty"     example:"alice@example.com"`
	Phone          *string `json:"phone,omitempty"     example:"14155552671"`
	Document       *string `json:"document,omitempty"  example:"12345678901"`
	EmployeeNumber *string `json:"employeeNumber,omitempty" example:"EMP-0042"`
	Bank           *string `json:"bank,omitempty"     example:"260"`
	Branch         *string `json:"branch,omitempty"   example:"0001"`
	Account        *string `json:"account,omitempty"     example:"1234567-8"`
	Pix            *string `json:"pix,omitempty"       example:"alice@example.com"`

	Addresses    []FindUsersByParamsAddressOutput        `json:"addresses,omitempty"`
	Dependents   []FindEmployeesByParamsDependentOutput  `json:"dependents,omitempty"`
	JobHistories []FindEmployeesByParamsJobHistoryOutput `json:"jobHistories,omitempty"`
}

// FindEmployeesByParamsDependentOutput is the nested wire shape of one
// Dependent inside a list item — the health-plan sibling fields render FLAT
// in the same object, mirroring the flat Go child.
type FindEmployeesByParamsDependentOutput struct {
	ID                 *string    `json:"id,omitempty"            example:"d8e6f4a2-1a3b-4c5d-9e7f-8a9b0c1d2e3f"`
	Name               *string    `json:"name,omitempty"          example:"Maria Silva"`
	BirthDate          *time.Time `json:"birthDate,omitempty"    example:"2015-03-10T00:00:00Z"`
	Relationship       *string    `json:"relationship,omitempty"    example:"daughter"`
	HealthPlanProvider *string    `json:"healthPlanProvider,omitempty"     example:"Unimed"`
	HealthPlanCard     *string    `json:"healthPlanCard,omitempty"   example:"UN-889923"`
	HealthPlanExpiry   *time.Time `json:"healthPlanExpiry,omitempty" example:"2027-12-31T00:00:00Z"`
}

// FindEmployeesByParamsJobHistoryOutput is the nested wire shape of one
// JobHistory inside a list item.
type FindEmployeesByParamsJobHistoryOutput struct {
	ID           *string    `json:"id,omitempty"           example:"a1b2c3d4-5e6f-4a8d-9f0e-9d2a8e6d4b51"`
	JobTitle     *string    `json:"jobTitle,omitempty"        example:"Engineer"`
	Department   *string    `json:"department,omitempty" example:"Platform"`
	HiredAt      *time.Time `json:"hiredAt,omitempty"     example:"2022-01-10T00:00:00Z"`
	TerminatedAt *time.Time `json:"terminatedAt,omitempty" example:"2024-06-30T00:00:00Z"`
}
