package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	"github.com/ClaudioSchirmer/omnicore/domain"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// PatchEmployeeCommand applies a partial update — each pointer is
// tri-state (nil = not sent, keeps current value). Children are NOT patchable
// (use PUT for atomic collection replacement); Document is absent (immutable
// natural key).
//
// The bank-account fields are doubly meaningful, like User's notification
// flags: the OUTER pointer is the PATCH tri-state, and the applied value is
// itself the *string the sibling stores. Sending any of them upserts the
// employee_bank_accounts row; omitting all four leaves the sibling
// untouched — the "PATCH does not touch the sibling" semantics the QA suite
// asserts.
type PatchEmployeeCommand struct {
	pipeline.CommandWithBodyIDBase
	Name           *string
	Email          *string
	Phone          *string
	EmployeeNumber *string

	Bank    *string
	Branch  *string
	Account *string
	Pix     *string
}

// ApplyPartiallyTo applies only the fields present in the body.
func (c *PatchEmployeeCommand) ApplyPartiallyTo(_ *configuration.AppContext, f *appdomain.Employee) error {
	if c.Name != nil {
		f.Name = *c.Name
	}
	if c.Email != nil {
		f.Email = *c.Email
	}
	if c.Phone != nil {
		f.Phone = c.Phone
	}
	if c.EmployeeNumber != nil {
		f.EmployeeNumber = *c.EmployeeNumber
	}
	if c.Bank != nil {
		f.Bank = c.Bank
	}
	if c.Branch != nil {
		f.Branch = c.Branch
	}
	if c.Account != nil {
		f.Account = c.Account
	}
	if c.Pix != nil {
		f.Pix = c.Pix
	}
	return nil
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FromEntity — same root + sibling snapshot the PUT path returns.
func (c *PatchEmployeeCommand) FromEntity(_ *configuration.AppContext, f *appdomain.Employee) (PatchEmployeeResult, error) {
	return PatchEmployeeResult{
		ID:             *f.GetID(),
		Name:           f.Name,
		Email:          f.Email,
		Phone:          f.Phone,
		Document:       f.Document,
		EmployeeNumber: f.EmployeeNumber,
		Bank:           f.Bank,
		Branch:         f.Branch,
		Account:        f.Account,
		Pix:            f.Pix,
	}, nil
}

// PatchEmployeeResult is the application-layer projection.
type PatchEmployeeResult struct {
	ID             domain.ID
	Name           string
	Email          string
	Phone          *string
	Document       string
	EmployeeNumber string
	Bank           *string
	Branch         *string
	Account        *string
	Pix            *string
}
