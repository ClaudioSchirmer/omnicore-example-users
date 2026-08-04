package vos

import "github.com/ClaudioSchirmer/omnicore/domain"

// HealthPlanType is the dependent-health-plan child-sibling's coverage enum,
// string-backed: the value IS the wire/persisted token.
type HealthPlanType string

// String-backed: the token IS the value (no iota to shift). Empty = zero
// sentinel, never a member.
const (
	HealthPlanTypeUnknown    HealthPlanType = ""
	HealthPlanTypeIndividual HealthPlanType = "individual"
	HealthPlanTypeFamily     HealthPlanType = "family"
	HealthPlanTypeCorporate  HealthPlanType = "corporate"
)

var healthPlanTypeMembers = []HealthPlanType{
	HealthPlanTypeIndividual, HealthPlanTypeFamily, HealthPlanTypeCorporate,
}

func (h HealthPlanType) Value() string            { return string(h) }
func (h HealthPlanType) Values() []HealthPlanType { return healthPlanTypeMembers }
func (h HealthPlanType) UnknownNotification() domain.Notification {
	return UnknownHealthPlanTypeNotification{}
}
