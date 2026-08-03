package vos

import (
	"regexp"

	"github.com/ClaudioSchirmer/omnicore/domain"
)

var emailRegex = regexp.MustCompile(`^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$`)

// Email is the shared Person e-mail value object: required, and shaped like an
// address. Reused by every role that carries an e-mail.
type Email string

// Value returns the underlying persistable primitive, satisfying
// domain.ValueObject[string].
func (e Email) Value() string { return string(e) }

func (e Email) IsValid(fieldName string, ctx *domain.NotificationContext) bool {
	if e == "" {
		ctx.AddNotification(fieldName, domain.RequiredFieldNotification{})
		return false
	}
	if !emailRegex.MatchString(string(e)) {
		ctx.AddNotification(fieldName, InvalidEmailNotification{}, string(e))
		return false
	}
	return true
}
