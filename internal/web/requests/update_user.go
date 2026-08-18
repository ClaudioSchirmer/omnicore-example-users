package requests

import (
	"github.com/ClaudioSchirmer/omnicore/domain"
	fwrequests "github.com/ClaudioSchirmer/omnicore/web/requests"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// UpdateUserRequest is the wire shape of PUT /users/:id (full replace, strict
// body — UpdateCommandHandler embeds FullBody in the framework). Shape
// mirrors UpdateUserCommand 1:1. All exported fields are mandatory — a field
// missing from the JSON fires 400 with RequiredFieldNotification per field
// (semantic Schema), via CommandWithBodyID + FullBody marker.
// Document is absent: it is the immutable natural key (not editable on any
// surface). EmailNotification/SmsNotification are *bool so PUT can clear the
// sibling by sending them null (a full replace with both null removes the
// user_configurations row).
type UpdateUserRequest struct {
	fwrequests.Auto

	Name                  string           `json:"name"                            example:"Alice Pereira"`
	Email                 string           `json:"email"                           example:"alice@example.com"`
	Phone                 *string          `json:"phone,omitempty"                 example:"14155552671"`
	Ethnicity             string           `json:"ethnicity"                       example:"white"`
	UserName              string           `json:"userName"                        example:"alice"`
	UserProfile           int              `json:"userProfile"                     example:"1"`
	EmailNotification     *bool            `json:"emailNotification,omitempty"     example:"true"`
	SmsNotification       *bool            `json:"smsNotification,omitempty"       example:"false"`
	NotificationEmail     *string          `json:"notificationEmail,omitempty"     example:"alice.notify@example.com"`
	NotificationFrequency *int             `json:"notificationFrequency,omitempty" example:"2"`
	Addresses             []AddressRequest `json:"addresses"`
}

// ToCommand converts the Request DTO into the Command. Boundary
// web→application: pure body assignment. AppContext is NOT received — the
// application layer (Command.ApplyTo) is where ctx interpretation happens.
func (r UpdateUserRequest) ToCommand() *commands.UpdateUserCommand {
	return fwrequests.AutoFromRequest[*commands.UpdateUserCommand](r)
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// UpdateUserResponse is the wire shape of PUT /users/:id on success. Carries
// the post-update root snapshot + the FULL aggregate mirror (the replaced
// address collection, with the ids the persister minted).
type UpdateUserResponse struct {
	fwresponses.Auto

	ID                    domain.ID                   `json:"id"                              example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Name                  string                      `json:"name"                            example:"Alice Pereira"`
	Email                 string                      `json:"email"                           example:"alice@example.com"`
	Phone                 *string                     `json:"phone,omitempty"                 example:"14155552671"`
	Document              string                      `json:"document"                        example:"12345678901"`
	Ethnicity             string                      `json:"ethnicity"                       example:"white"`
	UserName              string                      `json:"userName"                        example:"alice"`
	UserProfile           int                         `json:"userProfile"                     example:"1"`
	EmailNotification     *bool                       `json:"emailNotification,omitempty"     example:"true"`
	SmsNotification       *bool                       `json:"smsNotification,omitempty"       example:"false"`
	NotificationEmail     *string                     `json:"notificationEmail,omitempty"     example:"alice.notify@example.com"`
	NotificationFrequency *int                        `json:"notificationFrequency,omitempty" example:"2"`
	Addresses             []InsertUserResponseAddress `json:"addresses"`
}

func (UpdateUserResponse) FromResult(r commands.UpdateUserResult) UpdateUserResponse {
	return fwresponses.AutoFromResult[UpdateUserResponse](r)
}
