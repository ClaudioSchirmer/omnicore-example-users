package requests

import (
	"github.com/ClaudioSchirmer/omnicore/domain"
	fwrequests "github.com/ClaudioSchirmer/omnicore/web/requests"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// PatchUserRequest is the wire shape of PATCH /users/:id (partial update,
// lenient body). Shape mirrors PatchUserCommand 1:1 — all fields are *string
// tri-state (nil = absent; non-nil = apply). Address operations are not
// patchable here (use PUT to replace the collection).
type PatchUserRequest struct {
	fwrequests.Auto

	Name                  *string `json:"name,omitempty"                  example:"Alice Pereira"`
	Email                 *string `json:"email,omitempty"                 example:"alice@example.com"`
	Phone                 *string `json:"phone,omitempty"                 example:"14155552671"`
	Ethnicity             *string `json:"ethnicity,omitempty"             example:"white"`
	UserName              *string `json:"userName,omitempty"              example:"alice"`
	UserProfile           *int    `json:"userProfile,omitempty"           example:"1"`
	EmailNotification     *bool   `json:"emailNotification,omitempty"     example:"true"`
	SmsNotification       *bool   `json:"smsNotification,omitempty"       example:"false"`
	NotificationEmail     *string `json:"notificationEmail,omitempty"     example:"alice.notify@example.com"`
	NotificationFrequency *int    `json:"notificationFrequency,omitempty" example:"2"`
}

// ToCommand converts the Request DTO into the Command. Boundary
// web→application: pure body assignment. AppContext is NOT received — the
// application layer (Command.ApplyPartiallyTo) is where ctx interpretation
// happens.
func (r PatchUserRequest) ToCommand() *commands.PatchUserCommand {
	return fwrequests.AutoFromRequest[*commands.PatchUserCommand](r)
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// PatchUserResponse is the wire shape of PATCH /users/:id on success.
// Carries the post-patch root snapshot.
type PatchUserResponse struct {
	fwresponses.Auto

	ID                    domain.ID `json:"id"                              example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name                  string    `json:"name"                            example:"Alice Pereira"`
	Email                 string    `json:"email"                           example:"alice@example.com"`
	Phone                 *string   `json:"phone,omitempty"                 example:"14155552671"`
	Document              string    `json:"document"                        example:"12345678901"`
	Ethnicity             string    `json:"ethnicity"                       example:"white"`
	UserName              string    `json:"userName"                        example:"alice"`
	UserProfile           int       `json:"userProfile"                     example:"1"`
	EmailNotification     *bool     `json:"emailNotification,omitempty"     example:"true"`
	SmsNotification       *bool     `json:"smsNotification,omitempty"       example:"false"`
	NotificationEmail     *string   `json:"notificationEmail,omitempty"     example:"alice.notify@example.com"`
	NotificationFrequency *int      `json:"notificationFrequency,omitempty" example:"2"`
}

func (PatchUserResponse) FromResult(r commands.PatchUserResult) PatchUserResponse {
	return fwresponses.AutoFromResult[PatchUserResponse](r)
}
