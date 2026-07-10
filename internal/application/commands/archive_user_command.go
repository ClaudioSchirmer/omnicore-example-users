package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// ArchiveUserCommand triggers a soft-delete. ID comes from the URL path.
type ArchiveUserCommand struct{ pipeline.CommandByIDBase }

// ApplyTo is the hook for ctx → business translation on the archive verb.
// The framework calls it AFTER FindByID hydrates the aggregate and BEFORE
// GetArchivable runs BuildRules in ModeUpdate with actionName="GetArchivable".
//
// Populates two transient fields on the User so the domain's owner-check can
// run without reaching back into AppContext (DDD layering — the rule lives in
// domain/, the translation lives here):
//
//   - RequestingPrincipalEmail: the JWT email claim. The check fires when
//     this value differs from the User's persisted email.
//   - RequestingPrincipalIsAdmin: true when the principal carries the
//     users:admin permission. Bypasses the owner-check entirely.
//
// Tolerant of nil Identity (e.g. auth.mode=disabled in dev): both fields stay
// at their zero values, the principal-email check fails by default and the
// rule rejects unless the User has an empty email — which the domain forbids
// on Insert, so in practice archive will reject under auth=disabled with no
// admin override. This mirrors the "authz-on dev" trade-off; running the
// showcase with auth.mode=jwt + authorization.enabled=true is the canonical
// path.
func (*ArchiveUserCommand) ApplyTo(ctx *configuration.AppContext, u *appdomain.User) error {
	if ctx == nil {
		return nil
	}
	id := ctx.Identity()
	if id == nil {
		return nil
	}
	if email, _ := id.Claims["email"].(string); email != "" {
		u.RequestingPrincipalEmail = email
	}
	u.RequestingPrincipalIsAdmin = id.HasPermission("users:admin")
	return nil
}

// FromEntity returns fwresults.None — Archive verb emits the success envelope
// without a "data" field, matching the canonical bodyless verb shape.
func (*ArchiveUserCommand) FromEntity(_ *configuration.AppContext, _ *appdomain.User) (fwresults.None, error) {
	return fwresults.None{}, nil
}
