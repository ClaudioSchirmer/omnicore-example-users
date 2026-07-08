package dtos

import (
	"time"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// DependentInput is the application-layer DTO shared between the Insert and
// Update Employee commands. No JSON tags (wire format lives in
// web/requests/DependentRequest); types mirror the wire DTO 1:1 — the
// health-plan sibling fields carry pointers on both sides so ToDependent is a
// pure assignment (nil = no health-plan row).
type DependentInput struct {
	Name         string
	BirthDate    time.Time
	Relationship string

	HealthPlanProvider *string
	HealthPlanCard     *string
	HealthPlanExpiry   *time.Time
}

// ToDependent materializes an appdomain.Dependent — a direct copy, since the
// DTO already speaks application vocabulary.
func (d DependentInput) ToDependent() appdomain.Dependent {
	return appdomain.Dependent{
		Name:               d.Name,
		BirthDate:          d.BirthDate,
		Relationship:       d.Relationship,
		HealthPlanProvider: d.HealthPlanProvider,
		HealthPlanCard:     d.HealthPlanCard,
		HealthPlanExpiry:   d.HealthPlanExpiry,
	}
}
