package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/aggregatevos"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/vos"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// UpdateUserCommand carries the FULL desired state (PUT semantics).
// The framework's UpdateCommandHandler calls FindByID + ApplyTo + GetUpdatable,
// so ApplyTo replaces root fields and the full address collection.
//
// No JSON tags; shape mirrors UpdateUserRequest 1:1.
// Document is absent: it is the shared identity's immutable natural key, so the
// PUT surface does not accept it (User.BuildRules also rejects a change as a
// safety net).
type UpdateUserCommand struct {
	pipeline.CommandWithBodyIDBase
	Name                  string
	Email                 string
	Phone                 *string
	Ethnicity             string // enum token (string-backed)
	UserName              string
	UserProfile           int // enum value (int-backed)
	EmailNotification     *bool
	SmsNotification       *bool
	NotificationEmail     *string
	NotificationFrequency *int // enum value (int-backed), nullable
	Addresses             []dtos.AddressInput
}

// ApplyTo receives *AppContext alongside the loaded entity. Today the
// showcase doesn't consume ctx — a future authz field on User would be
// populated here (e.g., u.SetRequestingOwnerID(ctx.Identity().Subject)) for
// BuildRules' IfUpdate to compare against the persistent owner.
func (c UpdateUserCommand) ApplyTo(_ *configuration.AppContext, u *appdomain.User) error {
	u.Name = vos.Name(c.Name)
	u.Email = vos.Email(c.Email)
	u.Phone = (*vos.Phone)(c.Phone)
	u.Ethnicity = vos.Ethnicity(c.Ethnicity)
	u.UserName = vos.Name(c.UserName)
	u.UserProfile = vos.UserProfile(c.UserProfile)
	u.EmailNotification = c.EmailNotification
	u.SmsNotification = c.SmsNotification
	u.NotificationEmail = (*vos.Email)(c.NotificationEmail)
	u.NotificationFrequency = (*vos.NotificationFrequency)(c.NotificationFrequency)

	// Command speaks domain vocabulary to the root. ReplaceAddresses delegates
	// to ReplaceAggregateChildrenOf (which type-guards each item) — commands
	// no longer touch the framework's primitives directly.
	addrs := make([]aggregatevos.Address, len(c.Addresses))
	for i, a := range c.Addresses {
		addrs[i] = a.ToAddress()
	}
	u.ReplaceAddresses(addrs)
	return nil
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FromEntity is the symmetric inverse of ApplyTo — Entity → Result. The
// framework calls it AFTER orchestrator.Update completes; the receiver `c`
// gives access to whatever cmd-side data the projection needs.
func (c UpdateUserCommand) FromEntity(_ *configuration.AppContext, u *appdomain.User) (UpdateUserResult, error) {
	return UpdateUserResult{
		ID:                    *u.GetID(),
		Name:                  u.Name.Value(),
		Email:                 u.Email.Value(),
		Phone:                 (*string)(u.Phone),
		Document:              u.Document.Value(),
		Ethnicity:             u.Ethnicity.Value(),
		UserName:              u.UserName.Value(),
		UserProfile:           u.UserProfile.Value(),
		EmailNotification:     u.EmailNotification,
		SmsNotification:       u.SmsNotification,
		NotificationEmail:     (*string)(u.NotificationEmail),
		NotificationFrequency: (*int)(u.NotificationFrequency),
		// Full aggregate mirror — the PUT replaces the whole address set, so
		// the response carries the post-write collection with the minted ids
		// (written back into the aggregate map by the persister).
		Addresses: currentAddressResults(u),
	}, nil
}

// UpdateUserResult is the application-layer projection returned after the
// PUT completes. Pure data shape — no methods. The wire layer maps this to
// JSON via UpdateUserResponse.FromResult.
type UpdateUserResult struct {
	ID                    domain.ID
	Name                  string
	Email                 string
	Phone                 *string
	Document              string
	Ethnicity             string
	UserName              string
	UserProfile           int
	EmailNotification     *bool
	SmsNotification       *bool
	NotificationEmail     *string
	NotificationFrequency *int
	Addresses             []AddressResult
}
