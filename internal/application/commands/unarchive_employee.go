package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// UnarchiveEmployeeCommand restores a soft-deleted employee (symmetric
// cascade to the children archived alongside it). ID comes from the URL path.
type UnarchiveEmployeeCommand struct{ pipeline.CommandBaseWithID }

func (*UnarchiveEmployeeCommand) ApplyTo(_ *configuration.AppContext, _ *appdomain.Employee) error {
	return nil
}

// FromEntity returns fwresults.None — bodyless verb shape.
func (*UnarchiveEmployeeCommand) FromEntity(_ *configuration.AppContext, _ *appdomain.Employee) (fwresults.None, error) {
	return fwresults.None{}, nil
}
