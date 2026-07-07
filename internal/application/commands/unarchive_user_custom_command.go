package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// UnarchiveUserCustomCommand restores a soft-deleted user in the manual
// showcase chain. DocumentKey comes from the /:email path segment.
type UnarchiveUserCustomCommand struct {
	pipeline.CommandBase
	DocumentKey string
}

// ApplyTo is the hook for ctx → business translation on the unarchive verb.
// Symmetric to ArchiveUserCustomCommand.ApplyTo — the manual handler calls
// it AFTER FindArchivedByDocument hydrates the archived aggregate and BEFORE
// GetUnarchivable runs BuildRules in ModeUpdate with
// actionName="GetUnarchivable". No-op today; future authz would populate
// the transient identity field here.
func (*UnarchiveUserCustomCommand) ApplyTo(_ *configuration.AppContext, _ *appdomain.User) error {
	return nil
}

// FromEntity returns fwresults.None — bodyless verb shape.
func (*UnarchiveUserCustomCommand) FromEntity(_ *configuration.AppContext, _ *appdomain.User) (fwresults.None, error) {
	return fwresults.None{}, nil
}
