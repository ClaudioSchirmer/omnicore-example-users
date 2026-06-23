package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/dtos"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
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
// No JSON tags — wire format lives in web/requests/InsertUserCustomRequest;
// types mirror the Request 1:1.
type InsertUserCustomCommand struct {
	pipeline.CommandBase
	Name      string
	Email     string
	Phone     *string
	Addresses []dtos.AddressInputCustom
}

// ToEntity materializes an appdomain.User from the Command. Receives
// *AppContext so future identity-derived fields (JWT subject, tenant id,
// custom claims) translate into business-named entity fields here without
// touching the handler/wrapper signatures.
func (c InsertUserCustomCommand) ToEntity(_ *configuration.AppContext) (*appdomain.User, error) {
	u := &appdomain.User{
		Name:  c.Name,
		Email: c.Email,
		Phone: c.Phone,
	}
	for _, a := range c.Addresses {
		u.AddAddress(a.ToAddress(), nil)
	}
	return u, nil
}

// FromEntity projects the post-insert User into the shared UserCustomResult
// shape. Symmetric inverse of ToEntity — Cmd owns both input + output of
// the use case. Manual handlers call this AFTER orch.Insert + SetID, same
// as the canonical Auto path.
func (c InsertUserCustomCommand) FromEntity(_ *configuration.AppContext, u *appdomain.User) (UserCustomResult, error) {
	return userCustomResultFromUser(u), nil
}
