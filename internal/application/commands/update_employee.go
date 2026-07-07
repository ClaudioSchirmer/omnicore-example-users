package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// UpdateEmployeeCommand carries the FULL desired state (PUT semantics).
// Document is absent — the immutable natural key is not accepted on update.
// The three child collections are replaced atomically; the sibling facets
// (bank account on the root, health plan on each dependent) follow the PUT
// rule: absent (all-nil) = remove the row, present = upsert it.
type UpdateEmployeeCommand struct {
	pipeline.CommandBaseWithID
	Name           string
	Email          string
	Phone          *string
	EmployeeNumber string

	Bank    *string
	Branch  *string
	Account *string
	Pix     *string

	Addresses    []dtos.AddressInput
	Dependents   []dtos.DependentInput
	JobHistories []dtos.JobHistoryInput
}

// ApplyTo replaces root fields and the full child collections on the loaded
// entity — domain vocabulary only, no framework primitives.
func (c UpdateEmployeeCommand) ApplyTo(_ *configuration.AppContext, f *appdomain.Employee) error {
	f.Name = c.Name
	f.Email = c.Email
	f.Phone = c.Phone
	f.EmployeeNumber = c.EmployeeNumber
	f.Bank = c.Bank
	f.Branch = c.Branch
	f.Account = c.Account
	f.Pix = c.Pix

	addrs := make([]appdomain.Address, len(c.Addresses))
	for i, a := range c.Addresses {
		addrs[i] = a.ToAddress()
	}
	f.ReplaceAddresses(addrs)

	deps := make([]appdomain.Dependent, len(c.Dependents))
	for i, d := range c.Dependents {
		deps[i] = d.ToDependent()
	}
	f.ReplaceDependents(deps)

	hists := make([]appdomain.JobHistory, len(c.JobHistories))
	for i, h := range c.JobHistories {
		hists[i] = h.ToJobHistory()
	}
	f.ReplaceJobHistories(hists)
	return nil
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FromEntity — Entity → Result after the PUT completes.
func (c UpdateEmployeeCommand) FromEntity(_ *configuration.AppContext, f *appdomain.Employee) (UpdateEmployeeResult, error) {
	return UpdateEmployeeResult{
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

// UpdateEmployeeResult is the application-layer projection returned after
// the PUT completes.
type UpdateEmployeeResult struct {
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
