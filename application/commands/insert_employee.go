package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/dtos"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// InsertEmployeeCommand is the application-layer vocabulary for the
// "create Employee" use case. Like InsertUserCommand, the Employee is
// backed by the SHARED Person identity, so the POST is an UPSERT: when the
// person already exists (possibly created through the User role), the
// framework loads the identity + its base children (addresses) first and the
// command applies the request on top — that is the layer-6 base-reuse path
// this role exists to prove. Declares ApplyTo (not ToEntity) to satisfy
// pipeline.SharedBaseInsertCommand.
type InsertEmployeeCommand struct {
	pipeline.CommandBase
	Name           string
	Email          string
	Phone          *string
	Document       string
	EmployeeNumber string

	Bank    *string
	Branch  *string
	Account *string
	Pix     *string

	Addresses    []dtos.AddressInput
	Dependents   []dtos.DependentInput
	JobHistories []dtos.JobHistoryInput
}

// ApplyTo mutates the entity the handler supplies (fresh on a cold insert,
// loaded with the shared fields + base children on a warm upsert). Pure
// mapper: copies request fields and delegates to domain methods —
// AddAddress dedups against the person's existing addresses; the role-owned
// children are always fresh on insert.
func (c InsertEmployeeCommand) ApplyTo(_ *configuration.AppContext, f *appdomain.Employee) error {
	f.Name = c.Name
	f.Email = c.Email
	f.Phone = c.Phone
	f.Document = c.Document
	f.EmployeeNumber = c.EmployeeNumber
	f.Bank = c.Bank
	f.Branch = c.Branch
	f.Account = c.Account
	f.Pix = c.Pix
	for _, a := range c.Addresses {
		f.AddAddress(a.ToAddress(), nil)
	}
	for _, d := range c.Dependents {
		f.AddDependent(d.ToDependent())
	}
	for _, h := range c.JobHistories {
		f.AddJobHistory(h.ToJobHistory())
	}
	return nil
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FromEntity is the symmetric inverse of ApplyTo — Entity → Result, called
// after orchestrator.Insert + SetID. Root + sibling snapshot, mirroring the
// User surface (children are read through the view, not echoed here).
func (c InsertEmployeeCommand) FromEntity(_ *configuration.AppContext, f *appdomain.Employee) (InsertEmployeeResult, error) {
	return InsertEmployeeResult{
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

// InsertEmployeeResult is the application-layer projection returned by
// FromEntity. Pure data shape; the wire layer maps it via
// InsertEmployeeResponse.FromResult.
type InsertEmployeeResult struct {
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
