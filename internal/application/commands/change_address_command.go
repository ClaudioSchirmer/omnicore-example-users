package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// ChangeAddressCommand replaces ONE existing address inside the User aggregate,
// preserving the row's primary key. The address ID stays the same; the field
// values are replaced. The framework's auditor pairs pre/post by ID and emits
// the per-child op `changed` with the field-level delta — the only child op
// that the PUT-user-replace path cannot exercise (it always emits added/
// removed because ReplaceAddresses wipes the whole collection).
//
// PathID is the User UUID, auto-bound by the wrapper from the `:id` segment.
// AddressID comes from the `:addressId` segment via the Request DTO's
// `path:"addressId"` tag and is forwarded by ToCommand.
//
// ApplyTo delegates to User.ChangeAddressByID — which encapsulates the
// lookup, the not-found notification, and the cascade into
// ChangeAggregateChild. FromEntity reads cmd.AddressID directly (the
// receiver gives it access to the same input the framework dispatched) to
// project the post-mutation snapshot of that specific child.
//
// No JSON tags; shape mirrors ChangeAddressRequest 1:1.
type ChangeAddressCommand struct {
	pipeline.CommandWithBodyIDBase
	AddressID string
	Address   dtos.AddressInput
}

// ApplyTo delegates to the addressed-by-id domain method. The domain
// encapsulates the lookup + not-found notification + ChangeAggregateChild
// cascade.
func (c *ChangeAddressCommand) ApplyTo(_ *configuration.AppContext, u *appdomain.User) error {
	u.ChangeAddressByID(c.AddressID, c.Address.ToAddress())
	return nil
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FromEntity projects the post-mutation snapshot of the targeted address.
// Walks the aggregate's current children for the one whose ID matches
// cmd.AddressID — the receiver gives this projection direct access to the
// cmd-side identifier, no transient field needed on the entity.
func (c *ChangeAddressCommand) FromEntity(_ *configuration.AppContext, u *appdomain.User) (ChangeAddressResult, error) {
	out := ChangeAddressResult{UserID: *u.GetID()}
	for _, addr := range domain.GetCurrentItemsOf[appdomain.Address](&u.AggregateRoot) {
		if addr.GetID().Value() == c.AddressID {
			out.Address = toAddressResult(addr)
			break
		}
	}
	return out, nil
}

// ChangeAddressResult is the application-layer projection. Pure data shape.
// Carries the new state of the address that was changed plus the parent
// user's ID for link-back.
type ChangeAddressResult struct {
	UserID  domain.ID
	Address AddressResult
}

// AddressResult is the application-layer snapshot of one Address row.
// Symmetric inverse of dtos.AddressInput on the way in.
type AddressResult struct {
	ID           string
	Label        *string
	Street       string
	Number       string
	Complement   *string
	Neighborhood string
	City         string
	State        string
	ZipCode      string
	Country      string
}

// toAddressResult maps one domain Address to its application-layer snapshot.
func toAddressResult(a appdomain.Address) AddressResult {
	return AddressResult{
		ID:           a.GetID().Value(),
		Label:        a.Label,
		Street:       a.Street,
		Number:       a.Number,
		Complement:   a.Complement,
		Neighborhood: a.Neighborhood,
		City:         a.City,
		State:        a.State,
		ZipCode:      a.ZipCode,
		Country:      a.Country,
	}
}

// currentAddressResults projects the aggregate's current (non-removed)
// addresses — ids included: the persister writes each minted child PK back
// into the aggregate map, so a post-write projection carries them populated.
// Used by the insert/update FromEntity mirrors (the entity has the final
// word: the response reflects the post-write aggregate, never the input).
func currentAddressResults(u *appdomain.User) []AddressResult {
	items := domain.GetCurrentItemsOf[appdomain.Address](&u.AggregateRoot)
	out := make([]AddressResult, 0, len(items))
	for _, a := range items {
		out = append(out, toAddressResult(a))
	}
	return out
}
