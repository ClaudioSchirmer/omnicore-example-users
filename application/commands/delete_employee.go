package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// DeleteEmployeeCommand triggers a hard delete of the role row (the
// framework clears the role-owned child tables + siblings explicitly, then
// reference-counts the shared Person — the base purges only when NO role of
// any type still references it, under the vetoable-savepoint rules).
// ID comes from the URL path.
type DeleteEmployeeCommand struct{ pipeline.CommandBaseWithID }

func (*DeleteEmployeeCommand) ApplyTo(_ *configuration.AppContext, _ *appdomain.Employee) error {
	return nil
}

// FromEntity returns fwresults.None — bodyless verb shape.
func (*DeleteEmployeeCommand) FromEntity(_ *configuration.AppContext, _ *appdomain.Employee) (fwresults.None, error) {
	return fwresults.None{}, nil
}
