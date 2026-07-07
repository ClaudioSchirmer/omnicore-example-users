package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// UpdateUserCustomCommand is the PUT-shaped command consumed by the manual
// handler chain mounted under /showcase/users-custom/*. Two intentional
// differences from UpdateUserCommand:
//
//  1. Identification is by Document (the showcase mounts /:document in the
//     path), not the database UUID. DocumentKey is populated by the route
//     handler before Dispatch — there is no pipeline.CommandByIDBase
//     machinery because the manual path does not consume the SetPathID hook.
//
//  2. The mutable surface does NOT carry Document. Document is the immutable
//     natural key of the shared Person identity (it derives the deterministic
//     id), so it cannot be renamed on any surface; the canonical and custom
//     paths agree. Email, by contrast, IS now a plain mutable shared field and
//     is editable here.
//
// ApplyTo replaces every editable root field plus the entire address
// collection — same PUT semantic as the canonical UpdateUserCommand.
type UpdateUserCustomCommand struct {
	pipeline.CommandBase
	DocumentKey       string
	Name              string
	Email             string
	Phone             *string
	UserName          string
	EmailNotification *bool
	SmsNotification   *bool
	Addresses         []dtos.AddressInputCustom
}

// ApplyTo carries *AppContext alongside the loaded entity — same shape as the
// canonical UpdateUserCommand. Manual handlers wrap this call into a `func(T)`
// closure to feed domain.GetUpdatable; consumers that need ctx → business
// translation populate it here.
func (c *UpdateUserCustomCommand) ApplyTo(_ *configuration.AppContext, u *appdomain.User) error {
	u.Name = c.Name
	u.Email = c.Email
	u.Phone = c.Phone
	u.UserName = c.UserName
	u.EmailNotification = c.EmailNotification
	u.SmsNotification = c.SmsNotification

	addrs := make([]appdomain.Address, len(c.Addresses))
	for i, a := range c.Addresses {
		addrs[i] = a.ToAddress()
	}
	u.ReplaceAddresses(addrs)
	return nil
}

// FromEntity projects the post-update User into the shared UserCustomResult.
// Symmetric inverse of ApplyTo — Cmd owns both input + output. Manual handler
// calls this AFTER orch.Update completes.
func (c *UpdateUserCustomCommand) FromEntity(_ *configuration.AppContext, u *appdomain.User) (UserCustomResult, error) {
	return userCustomResultFromUser(u), nil
}
