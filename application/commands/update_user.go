package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/dtos"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// UpdateUserCommand carries the FULL desired state (PUT semantics).
// The framework's UpdateCommandHandler calls FindByID + ApplyTo + GetUpdatable,
// so ApplyTo replaces root fields and the full address collection.
//
// No JSON tags; shape mirrors UpdateUserRequest 1:1.
type UpdateUserCommand struct {
	pipeline.CommandBaseWithID
	Name      string
	Email     string
	Phone     *string
	Addresses []dtos.AddressInput
}

// ApplyTo receives *AppContext alongside the loaded entity. Today the
// showcase doesn't consume ctx — a future authz field on User would be
// populated here (e.g., u.SetRequestingOwnerID(ctx.Identity().Subject)) for
// BuildRules' IfUpdate to compare against the persistent owner.
func (c UpdateUserCommand) ApplyTo(_ *configuration.AppContext, u *appdomain.User) {
	u.Name = c.Name
	u.Email = c.Email
	u.Phone = c.Phone

	// Command speaks domain vocabulary to the root. ReplaceAddresses delegates
	// to ReplaceAggregateChildrenOf (which type-guards each item) — commands
	// no longer touch the framework's primitives directly.
	addrs := make([]appdomain.Address, len(c.Addresses))
	for i, a := range c.Addresses {
		addrs[i] = a.ToAddress()
	}
	u.ReplaceAddresses(addrs)
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FromEntity is the symmetric inverse of ApplyTo — Entity → Result. The
// framework calls it AFTER orchestrator.Update completes; the receiver `c`
// gives access to whatever cmd-side data the projection needs.
func (c UpdateUserCommand) FromEntity(_ *configuration.AppContext, u *appdomain.User) UpdateUserResult {
	return UpdateUserResult{
		ID:    *u.GetID(),
		Name:  u.Name,
		Email: u.Email,
		Phone: u.Phone,
	}
}

// UpdateUserResult is the application-layer projection returned after the
// PUT completes. Pure data shape — no methods. The wire layer maps this to
// JSON via UpdateUserResponse.FromResult.
type UpdateUserResult struct {
	ID    domain.ID
	Name  string
	Email string
	Phone *string
}
