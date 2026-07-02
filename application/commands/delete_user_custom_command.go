package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// DeleteUserCustomCommand triggers a hard delete (FK ON DELETE CASCADE on
// addresses) in the manual showcase chain. DocumentKey comes from the /:email
// path segment.
type DeleteUserCustomCommand struct {
	pipeline.CommandBase
	DocumentKey string
}

// ApplyTo is the hook for ctx → business translation on the delete verb.
// Symmetric to the canonical DeleteUserCommand.ApplyTo — the manual handler
// calls it AFTER FindByDocument and BEFORE GetDeletable runs BuildRules in
// ModeDelete (where the service uses IfDelete for delete-specific rules).
// No-op today; future authz would populate the transient identity field here.
func (*DeleteUserCustomCommand) ApplyTo(_ *configuration.AppContext, _ *appdomain.User) error {
	return nil
}

// FromEntity returns fwresults.None — bodyless verb shape.
func (*DeleteUserCustomCommand) FromEntity(_ *configuration.AppContext, _ *appdomain.User) (fwresults.None, error) {
	return fwresults.None{}, nil
}
