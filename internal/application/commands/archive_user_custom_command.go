package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// ArchiveUserCustomCommand triggers a soft-delete in the manual showcase chain.
// DocumentKey comes from the /:email path segment and is populated by the route
// handler before Dispatch.
type ArchiveUserCustomCommand struct {
	pipeline.CommandBase
	DocumentKey string
}

// ApplyTo is the hook for ctx → business translation on the archive verb.
// Symmetric to the canonical ArchiveUserCommand.ApplyTo. The manual handler
// calls it AFTER FindByDocument hydrates the aggregate and BEFORE GetArchivable
// runs BuildRules in ModeUpdate with actionName="GetArchivable". Today the
// showcase doesn't consume ctx — a future authz invariant would populate a
// transient field here (e.g., u.SetRequestingOwnerID(...)) for the service's
// IfUpdate branch on actionName=="GetArchivable" to validate.
func (*ArchiveUserCustomCommand) ApplyTo(_ *configuration.AppContext, _ *appdomain.User) error {
	return nil
}

// FromEntity returns fwresults.None — bodyless verb shape, same as canonical.
func (*ArchiveUserCustomCommand) FromEntity(_ *configuration.AppContext, _ *appdomain.User) (fwresults.None, error) {
	return fwresults.None{}, nil
}
