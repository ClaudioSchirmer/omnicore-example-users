package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// PatchUserCustomCommand is the PATCH-shaped command for the manual showcase
// chain under /showcase/users-custom/*. Identifier is Email (populated by the
// route handler before Dispatch); the mutable surface omits Email because in
// this route email is the key, not a data field.
//
// Same tri-state semantic as PatchUserCommand:
//
//	nil      → field not sent, keeps current value
//	non-nil  → replaces value (including empty string — consumer sent it;
//	           domain decides whether to reject)
//
// State transitions (archived/unarchived) and address operations are NOT
// patchable here — they live in the dedicated PATCH /:email/archive,
// /:email/unarchive and the full-replace PUT /:email endpoints, matching the
// canonical /users/* split.
type PatchUserCustomCommand struct {
	pipeline.CommandBase
	EmailKey string
	Name     *string
	Phone    *string
}

// ApplyPartiallyTo carries *AppContext alongside the loaded entity — same
// shape as the canonical PatchUserCommand. Manual handlers wrap this call
// into a `func(T)` closure to feed domain.GetPartialUpdatable.
func (c *PatchUserCustomCommand) ApplyPartiallyTo(_ *configuration.AppContext, u *appdomain.User) error {
	if c.Name != nil {
		u.Name = *c.Name
	}
	if c.Phone != nil {
		u.Phone = c.Phone
	}
	return nil
}

// FromEntity projects the post-patch User into the shared UserCustomResult.
// Manual handler calls this AFTER orch.Update via GetPartialUpdatable.
func (c *PatchUserCustomCommand) FromEntity(_ *configuration.AppContext, u *appdomain.User) (UserCustomResult, error) {
	return userCustomResultFromUser(u), nil
}
