package requests

import (
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	"github.com/ClaudioSchirmer/omnicore-example-users/application/dtos"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// InsertEmployeeRequest is the JSON wire shape of POST /employees.
// Shape identical to InsertEmployeeCommand; ToCommand is a 1:1 assignment.
// The bank-account block is optional (pointers) — absent means no
// employee_bank_accounts row; each dependent's plan block behaves the
// same one level down.
type InsertEmployeeRequest struct {
	Name           string  `json:"name"            example:"Alice Pereira"`
	Email          string  `json:"email"           example:"alice@example.com"`
	Phone          *string `json:"phone,omitempty" example:"14155552671"`
	Document       string  `json:"document"        example:"12345678901"`
	EmployeeNumber string  `json:"employeeNumber"       example:"EMP-0042"`

	Bank    *string `json:"bank,omitempty"   example:"260"`
	Branch  *string `json:"branch,omitempty" example:"0001"`
	Account *string `json:"account,omitempty"   example:"1234567-8"`
	Pix     *string `json:"pix,omitempty"     example:"alice@example.com"`

	Addresses    []AddressRequest    `json:"addresses,omitempty"`
	Dependents   []DependentRequest  `json:"dependents,omitempty"`
	JobHistories []JobHistoryRequest `json:"jobHistories,omitempty"`
}

// ToCommand converts the Request DTO into the Command — boundary
// web→application, pure body assignment.
func (r InsertEmployeeRequest) ToCommand() *commands.InsertEmployeeCommand {
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
	return &commands.InsertEmployeeCommand{
		Name:           r.Name,
		Email:          r.Email,
		Phone:          r.Phone,
		Document:       r.Document,
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

// InsertEmployeeResponse is the wire shape of POST /employees on
// success — root + sibling snapshot (children are read through the view).
type InsertEmployeeResponse struct {
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

// FromResult is the symmetric inverse of ToCommand — application Result →
// wire Response.
func (InsertEmployeeResponse) FromResult(r commands.InsertEmployeeResult) InsertEmployeeResponse {
	return InsertEmployeeResponse{
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
