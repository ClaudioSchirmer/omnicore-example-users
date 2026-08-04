package vos

import (
	"regexp"

	"github.com/ClaudioSchirmer/omnicore/domain"
)

var phoneRegex = regexp.MustCompile(`^\d{10,15}$`)

// Phone is the shared Person phone value object: OPTIONAL — an empty value is
// valid (the field is nullable) — but when present it must be 10–15 digits.
// The aggregate registers it only when its *string field is non-nil.
type Phone string

// Value returns the underlying persistable primitive, satisfying
// domain.ValueObject[string].
func (p Phone) Value() string { return string(p) }

func (p Phone) IsValid(fieldName string, ctx *domain.NotificationContext) bool {
	if p == "" {
		return true // optional — absence is not a violation
	}
	if !phoneRegex.MatchString(string(p)) {
		ctx.AddNotification(fieldName, InvalidPhoneNotification{}, string(p))
		return false
	}
	return true
}
