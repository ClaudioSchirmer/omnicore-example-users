package vos

import "github.com/ClaudioSchirmer/omnicore/domain"

// nameMaxLength caps the Person display name. The example hardcodes it; a
// production rule might resolve a per-tenant cap from a domain.Service — the
// notification shape would not change.
const nameMaxLength = 100

// Name is the shared Person display-name value object: required and
// length-capped.
type Name string

// Value returns the underlying persistable primitive, satisfying
// domain.ValueObject[string].
func (n Name) Value() string { return string(n) }

func (n Name) IsValid(fieldName string, ctx *domain.NotificationContext) bool {
	if n == "" {
		ctx.AddNotification(fieldName, domain.RequiredFieldNotification{})
		return false
	}
	if len(n) > nameMaxLength {
		ctx.AddNotification(fieldName, NameMaxLengthExceededNotification{MaxLength: nameMaxLength}, string(n))
		return false
	}
	return true
}
