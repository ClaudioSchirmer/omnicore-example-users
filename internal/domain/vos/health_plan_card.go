package vos

import (
	"regexp"

	"github.com/ClaudioSchirmer/omnicore/domain"
)

var healthPlanCardRegex = regexp.MustCompile(`^[0-9]{6,30}$`)

// HealthPlanCard is the dependent-health-plan child-sibling's card-number value
// object: OPTIONAL (the whole plan sibling is conditionally materialized), but
// when present it must be 6–30 digits.
type HealthPlanCard string

// Value returns the underlying persistable primitive (domain.ValueObject[string]).
func (c HealthPlanCard) Value() string { return string(c) }

func (c HealthPlanCard) IsValid(fieldName string, ctx *domain.NotificationContext) bool {
	if c == "" {
		return true // optional — absence is not a violation
	}
	if !healthPlanCardRegex.MatchString(string(c)) {
		ctx.AddNotification(fieldName, InvalidHealthPlanCardNotification{}, string(c))
		return false
	}
	return true
}
