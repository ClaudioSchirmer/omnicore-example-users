package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	"github.com/ClaudioSchirmer/omnicore/domain"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// PatchUserCommand applies a partial update — each pointer is tri-state:
//
//	nil      → field not sent, keeps current value
//	non-nil  → replaces value (including empty string — consumer sent it,
//	           domain decides whether to reject)
//
// State transitions (archived/unarchived) live in the dedicated endpoints
// PATCH /:id/archive and PATCH /:id/unarchive (aggregate-aware, cascade
// to addresses). PatchUserCommand does NOT accept "includeArchived" — the
// flag is a read-side wire concern, not a write-side field.
//
// Addresses are NOT patchable here — use PUT /:id (UpdateUserCommand) to
// replace the entire collection.
//
// No JSON tags; shape mirrors PatchUserRequest 1:1.
type PatchUserCommand struct {
	pipeline.CommandBaseWithID
	Name  *string
	Email *string
	Phone *string
}

// ApplyPartiallyTo receives *AppContext alongside the loaded entity. Same ctx
// semantics as Update's ApplyTo — today the showcase doesn't consume ctx; a
// future authz field on User would be populated here.
func (c *PatchUserCommand) ApplyPartiallyTo(_ *configuration.AppContext, u *appdomain.User) error {
	if c.Name != nil {
		u.Name = *c.Name
	}
	if c.Email != nil {
		u.Email = *c.Email
	}
	if c.Phone != nil {
		u.Phone = c.Phone
	}
	return nil
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FromEntity is the symmetric inverse of ApplyPartiallyTo — Entity → Result.
// Same root snapshot the PUT path returns; only the mutation rule (partial vs
// full) differs on the input side.
func (c *PatchUserCommand) FromEntity(_ *configuration.AppContext, u *appdomain.User) (PatchUserResult, error) {
	return PatchUserResult{
		ID:    *u.GetID(),
		Name:  u.Name,
		Email: u.Email,
		Phone: u.Phone,
	}, nil
}

// PatchUserResult is the application-layer projection. Pure data shape — no
// methods. Wire layer maps this to JSON via PatchUserResponse.FromResult.
type PatchUserResult struct {
	ID    domain.ID
	Name  string
	Email string
	Phone *string
}
