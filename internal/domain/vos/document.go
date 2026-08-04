package vos

import (
	"regexp"

	"github.com/ClaudioSchirmer/omnicore/domain"
)

// documentRegex shapes the Person natural key: 3–32 chars of letters, digits,
// dot or hyphen (e.g. "12345678901", "AB-1029"). Kept permissive on purpose —
// the point is "the natural key is validated like any other field", not a
// specific national-document format.
var documentRegex = regexp.MustCompile(`^[A-Za-z0-9.\-]{3,32}$`)

// Document is the shared Person natural-key value object: required and
// format-checked. Its immutability across an update is NOT part of this rule —
// that is a mode- and history-aware invariant (old vs new) and stays in the
// aggregate's IfUpdate, where domain.Old is available.
type Document string

// Value returns the underlying persistable primitive, satisfying
// domain.ValueObject[string].
func (d Document) Value() string { return string(d) }

func (d Document) IsValid(fieldName string, ctx *domain.NotificationContext) bool {
	if d == "" {
		ctx.AddNotification(fieldName, domain.RequiredFieldNotification{})
		return false
	}
	if !documentRegex.MatchString(string(d)) {
		ctx.AddNotification(fieldName, InvalidDocumentNotification{}, string(d))
		return false
	}
	return true
}
