package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// UnarchiveUserCommand restores a soft-deleted user. ID comes from the URL path.
type UnarchiveUserCommand struct{ pipeline.CommandByIDBase }

// ApplyTo is the hook for ctx → business translation on the unarchive verb.
// Symmetric to ArchiveUserCommand.ApplyTo — runs AFTER the archived
// aggregate is hydrated and BEFORE GetUnarchivable runs BuildRules in
// ModeUpdate with actionName="GetUnarchivable". No-op today; future authz
// would populate the transient identity field here.
func (*UnarchiveUserCommand) ApplyTo(_ *configuration.AppContext, _ *appdomain.User) error {
	return nil
}

// FromEntity returns fwresults.None — bodyless verb shape. Symmetric with
// the other Auto verbs (Archive/Delete) on this surface.
func (*UnarchiveUserCommand) FromEntity(_ *configuration.AppContext, _ *appdomain.User) (fwresults.None, error) {
	return fwresults.None{}, nil
}
