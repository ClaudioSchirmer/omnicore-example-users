package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// PatchUserCustomCommand is the PATCH-shaped command for the manual showcase
// chain under /showcase/users-custom/*. Identifier is Document (populated by the
// route handler before Dispatch); the mutable surface omits Document because it
// is the immutable natural key, not a data field. Email IS editable here (a
// plain mutable shared field).
//
// Same tri-state semantic as PatchUserCommand:
//
//	nil      → field not sent, keeps current value
//	non-nil  → replaces value (including empty string — consumer sent it;
//	           domain decides whether to reject)
//
// State transitions (archived/unarchived) and address operations are NOT
// patchable here — they live in the dedicated PATCH /:document/archive,
// /:document/unarchive and the full-replace PUT /:document endpoints, matching
// the canonical /users/* split.
type PatchUserCustomCommand struct {
	pipeline.CommandBase
	DocumentKey       string
	Name              *string
	Email             *string
	Phone             *string
	UserName          *string
	EmailNotification *bool
	SmsNotification   *bool
}

// ApplyPartiallyTo carries *AppContext alongside the loaded entity — same
// shape as the canonical PatchUserCommand. Manual handlers wrap this call
// into a `func(T)` closure to feed domain.GetPartialUpdatable.
func (c *PatchUserCustomCommand) ApplyPartiallyTo(_ *configuration.AppContext, u *appdomain.User) error {
	if c.Name != nil {
		u.Name = *c.Name
	}
	if c.Email != nil {
		u.Email = *c.Email
	}
	if c.Phone != nil {
		u.Phone = c.Phone
	}
	if c.UserName != nil {
		u.UserName = *c.UserName
	}
	if c.EmailNotification != nil {
		u.EmailNotification = c.EmailNotification
	}
	if c.SmsNotification != nil {
		u.SmsNotification = c.SmsNotification
	}
	return nil
}

// FromEntity projects the post-patch User into the shared UserCustomResult.
// Manual handler calls this AFTER orch.Update via GetPartialUpdatable.
func (c *PatchUserCustomCommand) FromEntity(_ *configuration.AppContext, u *appdomain.User) (UserCustomResult, error) {
	return userCustomResultFromUser(u), nil
}
