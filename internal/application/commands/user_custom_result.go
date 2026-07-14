package commands

import (
	"github.com/ClaudioSchirmer/omnicore/domain"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// UserCustomResult is the shared application-layer projection returned by every
// body-emitting handler of the manual showcase (Insert / Update / Patch). It
// is the analogue of the canonical InsertUserResult / UpdateUserResult /
// PatchUserResult triplet collapsed into a single struct — the manual surface
// deliberately keeps one response shape across its three body verbs.
//
// Go-pure: no JSON tags. The wire format (JSON names) lives in
// web/responses/UserCustomResponse, which maps this Result via FromResult.
// Result is a pure data shape — no methods, no behavior. Each Command of the
// manual showcase declares its own FromEntity returning a UserCustomResult
// via the userCustomResultFromUser helper below.
//
// Archive / Unarchive / Delete do not use this Result — they return
// fwresults.None, matching the canonical Auto handlers' "no data" default. The
// manual showcase no longer carries the "full body in any verb" identity; its
// value-add is the manual orchestration written out, not a divergent response
// shape per verb.
type UserCustomResult struct {
	ID                domain.ID
	Name              string
	Email             string
	Phone             *string
	Document          string
	UserName          string
	EmailNotification *bool
	SmsNotification   *bool
	Addresses         []AddressCustomResult
}

// AddressCustomResult is the snapshot of one Address row inside UserCustomResult.
// Optional fields stay as *string mirroring the domain entity, so the wire
// mapper can forward them unchanged with json:",omitempty" honored downstream.
type AddressCustomResult struct {
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

// userCustomResultFromUser packages the User aggregate into the shared
// UserCustomResult. Walks the current children (CONSTRUCTOR + ADDED, skipping
// REMOVED) so the snapshot reflects the post-mutation state every Command's
// FromEntity expects. The single Result shape is by design — keeps the
// wire surface stable across the three body verbs of the manual showcase.
//
// Lives here (next to the Result struct) rather than on the Result so the
// "Result is pure data" rule is observable at a glance — Cmds own the
// projection behavior, the Result owns the shape.
func userCustomResultFromUser(u *appdomain.User) UserCustomResult {
	addrs := domain.GetCurrentItemsOf[appdomain.Address](&u.AggregateRoot)
	out := make([]AddressCustomResult, len(addrs))
	for i, a := range addrs {
		out[i] = AddressCustomResult{
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
	return UserCustomResult{
		ID:                *u.GetID(),
		Name:              u.Name,
		Email:             u.Email,
		Phone:             u.Phone,
		Document:          u.Document,
		UserName:          u.UserName,
		EmailNotification: u.EmailNotification,
		SmsNotification:   u.SmsNotification,
		Addresses:         out,
	}
}
