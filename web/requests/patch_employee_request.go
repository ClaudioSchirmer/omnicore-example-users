package requests

import (
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// PatchEmployeeRequest is the wire shape of PATCH /employees/:id
// (partial update, lenient body). All fields tri-state pointers. Children are
// not patchable (use PUT); Document is the immutable natural key. Omitting
// the bank fields leaves the employee_bank_accounts sibling untouched —
// the "PATCH does not touch the sibling" semantics the QA suite asserts.
type PatchEmployeeRequest struct {
	Name           *string `json:"name,omitempty"      example:"Alice Pereira"`
	Email          *string `json:"email,omitempty"     example:"alice@example.com"`
	Phone          *string `json:"phone,omitempty"     example:"14155552671"`
	EmployeeNumber *string `json:"employeeNumber,omitempty" example:"EMP-0042"`

	Bank    *string `json:"bank,omitempty"   example:"260"`
	Branch  *string `json:"branch,omitempty" example:"0001"`
	Account *string `json:"account,omitempty"   example:"1234567-8"`
	Pix     *string `json:"pix,omitempty"     example:"alice@example.com"`
}

// ToCommand converts the Request DTO into the Command — pure body assignment.
func (r PatchEmployeeRequest) ToCommand() *commands.PatchEmployeeCommand {
	return &commands.PatchEmployeeCommand{
		Name:           r.Name,
		Email:          r.Email,
		Phone:          r.Phone,
		EmployeeNumber: r.EmployeeNumber,
		Bank:           r.Bank,
		Branch:         r.Branch,
		Account:        r.Account,
		Pix:            r.Pix,
	}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// PatchEmployeeResponse is the wire shape of PATCH /employees/:id on
// success — the post-patch root + sibling snapshot.
type PatchEmployeeResponse struct {
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

func (PatchEmployeeResponse) FromResult(r commands.PatchEmployeeResult) PatchEmployeeResponse {
	return PatchEmployeeResponse{
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
