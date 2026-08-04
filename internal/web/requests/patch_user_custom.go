package requests

import "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"

// PatchUserCustomRequest is the wire shape of
// PATCH /showcase/users-custom/:document. Mirrors PatchUserCustomCommand 1:1.
//
// Document carries no `json` tag — its value comes from the URL segment via
// `path:"document"`. Same rationale documented on UpdateUserCustomRequest:
// the /:document segment is the immutable identifier, not a body data field.
// Email IS patchable here (a plain mutable shared field). Address operations
// are NOT patchable here; use PUT to replace the collection.
type PatchUserCustomRequest struct {
	Document              string  `path:"document"`
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

// ToCommand converts the Request DTO into the Command. DocumentKey comes from
// req.Document — populated by fwweb.BindPath from the /:document URL segment
// before c.Bind().Body().
func (r PatchUserCustomRequest) ToCommand() *commands.PatchUserCustomCommand {
	return &commands.PatchUserCustomCommand{
		DocumentKey:           r.Document,
		Name:                  r.Name,
		Email:                 r.Email,
		Phone:                 r.Phone,
		Ethnicity:             r.Ethnicity,
		UserName:              r.UserName,
		UserProfile:           r.UserProfile,
		EmailNotification:     r.EmailNotification,
		SmsNotification:       r.SmsNotification,
		NotificationEmail:     r.NotificationEmail,
		NotificationFrequency: r.NotificationFrequency,
	}
}
