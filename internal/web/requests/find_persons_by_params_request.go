package requests

import (
	"time"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// FindPersonsByParamsRequest declares the wire allowlist for GET /persons —
// the all-in-one person view (SharedBaseView). Root filters address the
// shared Person fields; the role segments surface as embed groups (a
// struct-typed field with a query prefix), so ?user.userName=alice and
// ?employee.dependents.relationship=daughter resolve to Go field paths the
// reader translates through the view's role nodes. The embed-group FIELD
// NAMES ("User", "Employee") must equal the role segments the view derives
// from the role Go types — that is the contract that makes the wire path
// land on the right sub-document.
type FindPersonsByParamsRequest struct {
	Name     *string `query:"name"     filter:"eq,startswith,icontains,istartswith"`
	Email    *string `query:"email"    filter:"eq,in,ieq"`
	Document *string `query:"document" filter:"eq,in,startswith"`

	Addresses AddressFilterParams        `query:"addresses"`
	User      PersonUserFilterParams     `query:"user"`
	Employee  PersonEmployeeFilterParams `query:"employee"`

	Limit           *int64  `query:"limit"`
	After           *string `query:"after"`
	Before          *string `query:"before"`
	Sort            *string `query:"sort"`
	Fields          *string `query:"fields"`
	Search          *string `query:"search"`
	IncludeArchived *bool   `query:"includeArchived"`
	OnlyTotal       *bool   `query:"onlyTotal"`
}

// PersonUserFilterParams is the embed-group filter vocabulary for the User
// role segment — role-private fields plus the notification sibling leaf.
type PersonUserFilterParams struct {
	UserName          *string `query:"userName"          filter:"eq,in,istartswith"`
	EmailNotification *bool   `query:"emailNotification" filter:"eq"`
}

// PersonEmployeeFilterParams is the embed-group filter vocabulary for the
// Employee role segment — role fields, the bank sibling leaf, and the role's
// child collections one level further in.
type PersonEmployeeFilterParams struct {
	EmployeeNumber *string `query:"employeeNumber" filter:"eq,in,startswith"`
	Bank           *string `query:"bank"           filter:"eq,in"`

	Dependents   DependentFilterParams  `query:"dependents"`
	JobHistories JobHistoryFilterParams `query:"jobHistories"`
}

func (r FindPersonsByParamsRequest) ToQuery(criteria fwqueries.ReadCriteria) *queries.FindPersonByParamsQuery {
	return &queries.FindPersonByParamsQuery{Criteria: criteria}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FindPersonsByParamsResponse is the wire projection of one person document in
// the GET /persons list. Shared fields render flat at the root; the shared
// addresses nest at the root; each role renders as an optional sub-object —
// the struct FIELD name equals the role segment ("User"/"Employee") so
// AutoFromDoc keys it, and the json tag gives the wire name. A person without
// a role simply omits that key (null segment + omitempty); an archived role is
// omitted on default reads and carries its deletedAt under
// ?includeArchived=true.
type FindPersonsByParamsResponse struct {
	ID       *string `json:"id,omitempty"       example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name     *string `json:"name,omitempty"     example:"Alice Pereira"`
	Email    *string `json:"email,omitempty"    example:"alice@example.com"`
	Phone    *string `json:"phone,omitempty"    example:"14155552671"`
	Document *string `json:"document,omitempty" example:"12345678901"`

	Addresses []FindUsersByParamsAddressOutput `json:"addresses,omitempty"`
	User      *PersonUserOutput                `json:"user,omitempty"`
	Employee  *PersonEmployeeOutput            `json:"employee,omitempty"`
}

// PersonUserOutput is the User role segment on the wire: role-private fields
// plus the notification sibling flat, mirroring the composed sub-document.
type PersonUserOutput struct {
	ID                *string    `json:"id,omitempty"                example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	UserName          *string    `json:"userName,omitempty"          example:"alice"`
	EmailNotification *bool      `json:"emailNotification,omitempty" example:"true"`
	SmsNotification   *bool      `json:"smsNotification,omitempty"   example:"false"`
	DeletedAt         *time.Time `json:"deletedAt,omitempty"         example:"2026-07-01T12:00:00Z"`
}

// PersonEmployeeOutput is the Employee role segment on the wire: role fields,
// the bank sibling flat, and the role-owned collections nested inside.
type PersonEmployeeOutput struct {
	ID             *string    `json:"id,omitempty"             example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	EmployeeNumber *string    `json:"employeeNumber,omitempty" example:"EMP-0042"`
	Bank           *string    `json:"bank,omitempty"           example:"260"`
	Branch         *string    `json:"branch,omitempty"         example:"0001"`
	Account        *string    `json:"account,omitempty"        example:"1234567-8"`
	Pix            *string    `json:"pix,omitempty"            example:"alice@example.com"`
	DeletedAt      *time.Time `json:"deletedAt,omitempty"      example:"2026-07-01T12:00:00Z"`

	Dependents   []FindEmployeesByParamsDependentOutput  `json:"dependents,omitempty"`
	JobHistories []FindEmployeesByParamsJobHistoryOutput `json:"jobHistories,omitempty"`
}
