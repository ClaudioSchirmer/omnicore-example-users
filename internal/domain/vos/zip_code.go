package vos

import (
	"regexp"

	"github.com/ClaudioSchirmer/omnicore/domain"
)

var zipCodeRegex = regexp.MustCompile(`^[A-Za-z0-9 \-]{3,12}$`)

// ZipCode is the Address child's postal-code value object: required, permissive
// format (the showcase point is "validated like any field", not one country).
type ZipCode string

// Value returns the underlying persistable primitive (domain.ValueObject[string]).
func (z ZipCode) Value() string { return string(z) }

func (z ZipCode) IsValid(fieldName string, ctx *domain.NotificationContext) bool {
	if z == "" {
		ctx.AddNotification(fieldName, domain.RequiredFieldNotification{})
		return false
	}
	if !zipCodeRegex.MatchString(string(z)) {
		ctx.AddNotification(fieldName, InvalidZipCodeNotification{}, string(z))
		return false
	}
	return true
}
