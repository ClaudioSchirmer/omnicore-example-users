package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// DeleteUserCommand triggers a hard delete (cascade addresses via FK
// ON DELETE CASCADE). ID comes from the URL path.
type DeleteUserCommand struct{ pipeline.CommandBaseWithID }

// ApplyTo is the hook for ctx → business translation on the delete verb.
// Runs AFTER FindByID and BEFORE GetDeletable runs BuildRules in ModeDelete
// (where the service uses IfDelete for delete-specific rules). No-op today;
// future authz would populate the transient identity field here.
func (*DeleteUserCommand) ApplyTo(_ *configuration.AppContext, _ *appdomain.User) {}

// FromEntity returns fwresults.None — bodyless verb shape. Symmetric with
// the other Auto verbs (Archive/Unarchive) on this surface.
func (*DeleteUserCommand) FromEntity(_ *configuration.AppContext, _ *appdomain.User) fwresults.None {
	return fwresults.None{}
}
