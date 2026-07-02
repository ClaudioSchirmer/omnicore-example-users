package requests

import (
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	"github.com/ClaudioSchirmer/omnicore-example-users/application/dtos"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// UpdateEmployeeRequest is the wire shape of PUT /employees/:id (full
// replace, strict body via the FullBody marker on UpdateCommandHandler — every
// exported field must be PRESENT in the JSON; nullable pointers may be
// explicit nulls).
// Document is absent — the immutable natural key is not editable. A PUT sending
// all four bank fields as null REMOVES the
// employee_bank_accounts row; a dependent without its plan block
// removes that dependent's health-plan row — the PUT sibling semantics the
// QA suite asserts.
type UpdateEmployeeRequest struct {
	Name           string  `json:"name"            example:"Alice Pereira"`
	Email          string  `json:"email"           example:"alice@example.com"`
	Phone          *string `json:"phone,omitempty" example:"14155552671"`
	EmployeeNumber string  `json:"employeeNumber"       example:"EMP-0042"`

	Bank    *string `json:"bank,omitempty"   example:"260"`
	Branch  *string `json:"branch,omitempty" example:"0001"`
	Account *string `json:"account,omitempty"   example:"1234567-8"`
	Pix     *string `json:"pix,omitempty"     example:"alice@example.com"`

	Addresses    []AddressRequest    `json:"addresses"`
	Dependents   []DependentRequest  `json:"dependents"`
	JobHistories []JobHistoryRequest `json:"jobHistories"`
}

// ToCommand converts the Request DTO into the Command — pure body assignment.
func (r UpdateEmployeeRequest) ToCommand() *commands.UpdateEmployeeCommand {
	addrs := make([]dtos.AddressInput, len(r.Addresses))
	for i, a := range r.Addresses {
		addrs[i] = a.ToAddressInput()
	}
	deps := make([]dtos.DependentInput, len(r.Dependents))
	for i, d := range r.Dependents {
		deps[i] = d.ToDependentInput()
	}
	hists := make([]dtos.JobHistoryInput, len(r.JobHistories))
	for i, h := range r.JobHistories {
		hists[i] = h.ToJobHistoryInput()
	}
	return &commands.UpdateEmployeeCommand{
		Name:           r.Name,
		Email:          r.Email,
		Phone:          r.Phone,
		EmployeeNumber: r.EmployeeNumber,
		Bank:           r.Bank,
		Branch:         r.Branch,
		Account:        r.Account,
		Pix:            r.Pix,
		Addresses:      addrs,
		Dependents:     deps,
		JobHistories:   hists,
	}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// UpdateEmployeeResponse is the wire shape of PUT /employees/:id on
// success — the post-update root + sibling snapshot.
type UpdateEmployeeResponse struct {
	ID             domain.ID `json:"id"                example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name           string    `json:"name"              example:"Alice Pereira"`
	Email          string    `json:"email"             example:"alice@example.com"`
	Phone          *string   `json:"phone,omitempty"   example:"14155552671"`
	Document       string    `json:"document"          example:"12345678901"`
	EmployeeNumber string    `json:"employeeNumber"         example:"EMP-0042"`
	Bank           *string   `json:"bank,omitempty"   example:"260"`
	Branch         *string   `json:"branch,omitempty" example:"0001"`
	Account        *string   `json:"account,omitempty"   example:"1234567-8"`
	Pix            *string   `json:"pix,omitempty"     example:"alice@example.com"`
}

func (UpdateEmployeeResponse) FromResult(r commands.UpdateEmployeeResult) UpdateEmployeeResponse {
	return UpdateEmployeeResponse{
		ID:             r.ID,
		Name:           r.Name,
		Email:          r.Email,
		Phone:          r.Phone,
		Document:       r.Document,
		EmployeeNumber: r.EmployeeNumber,
		Bank:           r.Bank,
		Branch:         r.Branch,
		Account:        r.Account,
		Pix:            r.Pix,
	}
}
