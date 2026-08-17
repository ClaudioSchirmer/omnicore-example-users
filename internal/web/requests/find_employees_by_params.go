package requests

import (
	"time"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

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
	Ethnicity      *string `query:"ethnicity" filter:"eq,in"`
	EmployeeNumber *string `query:"employeeNumber" filter:"eq,in,startswith"`
	Bank           *string `query:"bank"     filter:"eq,in"`

	Addresses    AddressFilterParams    `query:"addresses"`
	Dependents   DependentFilterParams  `query:"dependents"`
	JobHistories JobHistoryFilterParams `query:"jobHistories"`

	First           *int64  `query:"first"`
	Last            *int64  `query:"last"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	OrderBy         *string `query:"orderBy"`
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
	HealthPlanType     *string `query:"healthPlanType" filter:"eq,in"`
}

// JobHistoryFilterParams is the embed-group filter vocabulary for the
// jobHistories child.
type JobHistoryFilterParams struct {
	JobTitle   *string `query:"jobTitle"        filter:"eq,istartswith,icontains"`
	Department *string `query:"department" filter:"eq,in"`
}

func (r FindEmployeesByParamsRequest) ToQuery(criteria fwqueries.ReadCriteria) *queries.FindEmployeesByParamsQuery {
	return &queries.FindEmployeesByParamsQuery{Criteria: criteria}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FindEmployeesByParamsResponse is the wire projection of one Employee
// view document in the GET /employees list. Every field is a pointer (or
// slice) with omitempty — the sparse-render contract behind `?fields=`.
// The shared Person fields and the bank sibling render FLAT at the root,
// exactly as the composer stores them.
type FindEmployeesByParamsResponse struct {
	ID             *string `json:"id,omitempty"        example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name           *string `json:"name,omitempty" exportLabelKey:"UserNameField"      example:"Alice Pereira"`
	Email          *string `json:"email,omitempty" exportLabelKey:"UserEmailField"     example:"alice@example.com"`
	Phone          *string `json:"phone,omitempty" exportLabelKey:"UserPhoneField"     example:"14155552671"`
	Document       *string `json:"document,omitempty" exportLabelKey:"UserDocumentField"  example:"12345678901"`
	Ethnicity      *string `json:"ethnicity,omitempty" exportLabelKey:"PersonEthnicityField" example:"white"`
	EmployeeNumber *string `json:"employeeNumber,omitempty" exportLabelKey:"EmployeeNumberField" example:"EMP-0042"`
	Bank           *string `json:"bank,omitempty" exportLabelKey:"EmployeeBankField"     example:"260"`
	Branch         *string `json:"branch,omitempty" exportLabelKey:"EmployeeBranchField"   example:"0001"`
	Account        *string `json:"account,omitempty" exportLabelKey:"EmployeeAccountField"     example:"1234567-8"`
	Pix            *string `json:"pix,omitempty" exportLabelKey:"EmployeePixField"       example:"alice@example.com"`

	Addresses    []FindUsersByParamsAddressOutput        `json:"addresses,omitempty"`
	Dependents   []FindEmployeesByParamsDependentOutput  `json:"dependents,omitempty"`
	JobHistories []FindEmployeesByParamsJobHistoryOutput `json:"jobHistories,omitempty"`
}

// FromResult is the wire mapping seat, delegating to the generic name-based
// mapper — the read-side twin of the command Responses' FromResult.
func (FindEmployeesByParamsResponse) FromResult(r queries.FindEmployeesByParamsResult) FindEmployeesByParamsResponse {
	return fwresponses.Map[FindEmployeesByParamsResponse](r)
}

// FindEmployeesByParamsDependentOutput is the nested wire shape of one
// Dependent inside a list item — the health-plan sibling fields render FLAT
// in the same object, mirroring the flat Go child.
type FindEmployeesByParamsDependentOutput struct {
	ID                 *string    `json:"id,omitempty"            example:"d8e6f4a2-1a3b-4c5d-9e7f-8a9b0c1d2e3f"`
	Name               *string    `json:"name,omitempty" exportLabelKey:"DependentNameField"          example:"Maria Silva"`
	BirthDate          *time.Time `json:"birthDate,omitempty" exportLabelKey:"DependentBirthDateField"    example:"2015-03-10T00:00:00Z"`
	Relationship       *string    `json:"relationship,omitempty" exportLabelKey:"DependentRelationshipField"    example:"daughter"`
	HealthPlanProvider *string    `json:"healthPlanProvider,omitempty" exportLabelKey:"DependentHealthPlanProviderField"     example:"Unimed"`
	HealthPlanCard     *string    `json:"healthPlanCard,omitempty" exportLabelKey:"DependentHealthPlanCardField"   example:"UN-889923"`
	HealthPlanExpiry   *time.Time `json:"healthPlanExpiry,omitempty" exportLabelKey:"DependentHealthPlanExpiryField" example:"2027-12-31T00:00:00Z"`
	HealthPlanType     *string    `json:"healthPlanType,omitempty" exportLabelKey:"DependentHealthPlanTypeField"   example:"individual"`
}

// FindEmployeesByParamsJobHistoryOutput is the nested wire shape of one
// JobHistory inside a list item.
type FindEmployeesByParamsJobHistoryOutput struct {
	ID           *string    `json:"id,omitempty"           example:"a1b2c3d4-5e6f-4a8d-9f0e-9d2a8e6d4b51"`
	JobTitle     *string    `json:"jobTitle,omitempty" exportLabelKey:"JobHistoryJobTitleField"        example:"Engineer"`
	Department   *string    `json:"department,omitempty" exportLabelKey:"JobHistoryDepartmentField" example:"Platform"`
	HiredAt      *time.Time `json:"hiredAt,omitempty" exportLabelKey:"JobHistoryHiredAtField"     example:"2022-01-10T00:00:00Z"`
	TerminatedAt *time.Time `json:"terminatedAt,omitempty" exportLabelKey:"JobHistoryTerminatedAtField" example:"2024-06-30T00:00:00Z"`
}
