package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// InsertUserCustomCommand is the application-layer vocabulary for the "create
// User" use case on the manual showcase chain mounted under
// /showcase/users-custom/*. Same shape as the canonical InsertUserCommand —
// the didactic point of the showcase is to expose every layer above
// domain/ as a parallel copy so the symmetry with Update/Patch/Archive/
// Unarchive/Delete custom twins is visible at a glance. Only domain/ is
// reused across the two surfaces; everything from application/ upwards has
// its own dedicated symbols.
//
// Like the canonical InsertUserCommand, the User is SharedBase-backed so the
// POST is an UPSERT: the command declares ApplyTo (mutate the loaded-or-fresh
// entity), and the manual handler hydrates the existing Person identity before
// applying it. No JSON tags — wire format lives in
// web/requests/InsertUserCustomRequest; types mirror the Request 1:1.
type InsertUserCustomCommand struct {
	pipeline.CommandBase
	Name              string
	Email             string
	Phone             *string
	Document          string
	UserName          string
	EmailNotification *bool
	SmsNotification   *bool
	Addresses         []dtos.AddressInputCustom
}

// ApplyTo mutates the entity the manual handler supplies — fresh on a cold
// insert, loaded (with the person's existing addresses as Constructor items) on
// a warm upsert, so u.AddAddress dedups the request's addresses against them.
// Pure mapper (the handler also calls it on a throwaway entity to read the
// natural key). Receives *AppContext for the same identity-translation seam as
// the canonical command.
func (c InsertUserCustomCommand) ApplyTo(_ *configuration.AppContext, u *appdomain.User) error {
	u.Name = c.Name
	u.Email = c.Email
	u.Phone = c.Phone
	u.Document = c.Document
	u.UserName = c.UserName
	u.EmailNotification = c.EmailNotification
	u.SmsNotification = c.SmsNotification
	for _, a := range c.Addresses {
		u.AddAddress(a.ToAddress(), nil)
	}
	return nil
}

// FromEntity projects the post-insert User into the shared UserCustomResult
// shape. Symmetric inverse of ApplyTo — Cmd owns both input + output of
// the use case. Manual handlers call this AFTER orch.Insert + SetID, same
// as the canonical Auto path.
func (c InsertUserCustomCommand) FromEntity(_ *configuration.AppContext, u *appdomain.User) (UserCustomResult, error) {
	return userCustomResultFromUser(u), nil
}
