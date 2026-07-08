package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// ChangeAddressCustomCommand is the manual showcase twin of
// ChangeAddressCommand. Same business behavior — replace one address inside
// the user aggregate preserving its primary key — exposed under
// /showcase/users-custom/:email/addresses/:addressId. Two intentional
// differences from the canonical:
//
//  1. Identifier is Email instead of User UUID (matches the manual
//     showcase's surface convention; ApplyTo doesn't see Email — it just
//     mutates the User the handler already loaded via FindByDocument).
//  2. No pipeline.CommandByIDBase — the manual chain does not consume the
//     SetPathID hook. The route handler assembles the command inline from
//     the Request DTO's path-bound fields.
//
// ApplyTo delegates to the SAME domain method as the canonical Command
// (u.ChangeAddressByID) so both surfaces produce identical auditor
// behavior — kind=delta + children.Address[*].op=changed with the
// field-level delta. FromEntity projects the shared UserCustomResult — the
// manual showcase keeps one wire shape across its three body verbs
// (Insert/Update/Patch) plus this fourth verb that targets a child.
type ChangeAddressCustomCommand struct {
	pipeline.CommandBase
	DocumentKey string
	AddressID   string
	Address     dtos.AddressInputCustom
}

// ApplyTo delegates to the addressed-by-id domain method — same shape as
// the canonical Command.
func (c *ChangeAddressCustomCommand) ApplyTo(_ *configuration.AppContext, u *appdomain.User) error {
	u.ChangeAddressByID(c.AddressID, c.Address.ToAddress())
	return nil
}

// FromEntity projects the post-mutation User into the shared UserCustomResult.
// Manual handler calls this AFTER orch.Update completes.
func (c *ChangeAddressCustomCommand) FromEntity(_ *configuration.AppContext, u *appdomain.User) (UserCustomResult, error) {
	return userCustomResultFromUser(u), nil
}
