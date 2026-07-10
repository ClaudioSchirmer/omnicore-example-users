package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// ArchiveEmployeeCommand triggers a soft-delete (cascade to the role-owned
// dependents/job history plus the shared base per convergeBase). ID comes from
// the URL path. Unlike ArchiveUserCommand there is no Layer-2 owner-check
// here — the Employee surface exercises Layer 1 only (the User surface
// already covers Layer 2).
type ArchiveEmployeeCommand struct{ pipeline.CommandByIDBase }

func (*ArchiveEmployeeCommand) ApplyTo(_ *configuration.AppContext, _ *appdomain.Employee) error {
	return nil
}

// FromEntity returns fwresults.None — bodyless verb shape.
func (*ArchiveEmployeeCommand) FromEntity(_ *configuration.AppContext, _ *appdomain.Employee) (fwresults.None, error) {
	return fwresults.None{}, nil
}
