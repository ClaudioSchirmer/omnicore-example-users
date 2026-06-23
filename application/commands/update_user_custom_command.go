package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/dtos"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// UpdateUserCustomCommand is the PUT-shaped command consumed by the manual
// handler chain mounted under /showcase/users-custom/*. Two intentional
// differences from UpdateUserCommand:
//
//  1. Identification is by Email (the showcase mounts /:email in the path),
//     not the database UUID. EmailKey is populated by the route handler
//     before Dispatch — there is no pipeline.CommandBaseWithID machinery
//     because the manual path does not consume the SetPathID hook.
//
//  2. The mutable surface does NOT carry Email. Email is the identifier in
//     this route; renaming would change the very key the URL pinned, so the
//     custom path treats it as immutable. To rename, the consumer deletes
//     and recreates via POST. The canonical /users/:id (UUID-keyed) route
//     continues to allow renaming as before.
//
// ApplyTo replaces every editable root field plus the entire address
// collection — same PUT semantic as the canonical UpdateUserCommand.
type UpdateUserCustomCommand struct {
	pipeline.CommandBase
	EmailKey  string
	Name      string
	Phone     *string
	Addresses []dtos.AddressInputCustom
}

// ApplyTo carries *AppContext alongside the loaded entity — same shape as the
// canonical UpdateUserCommand. Manual handlers wrap this call into a `func(T)`
// closure to feed domain.GetUpdatable; consumers that need ctx → business
// translation populate it here.
func (c *UpdateUserCustomCommand) ApplyTo(_ *configuration.AppContext, u *appdomain.User) error {
	u.Name = c.Name
	u.Phone = c.Phone

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
