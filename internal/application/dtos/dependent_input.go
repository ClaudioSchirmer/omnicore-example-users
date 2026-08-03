package dtos

import (
	"time"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/aggregatevos"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/vos"
)

// DependentInput is the application-layer DTO shared between the Insert and
// Update Employee commands. No JSON tags (wire format lives in
// web/requests/DependentRequest); the wire fields carry the value objects'
// underlying scalars (a string token for Relationship/HealthPlanType, a string
// for HealthPlanCard) — ToDependent converts them to the value-object types.
type DependentInput struct {
	Name         string
	BirthDate    time.Time
	Relationship string // enum token (string-backed)

	HealthPlanProvider *string
	HealthPlanCard     *string
	HealthPlanExpiry   *time.Time
	HealthPlanType     *string // enum token (string-backed), nullable
}

// ToDependent materializes an aggregatevos.Dependent. Value objects: the wire
// value IS the underlying, so each is a plain conversion; the nullable ones are
// a nil-safe pointer conversion.
func (d DependentInput) ToDependent() aggregatevos.Dependent {
	return aggregatevos.Dependent{
		Name:               d.Name,
		BirthDate:          d.BirthDate,
		Relationship:       vos.Relationship(d.Relationship),
		HealthPlanProvider: d.HealthPlanProvider,
		HealthPlanCard:     (*vos.HealthPlanCard)(d.HealthPlanCard),
		HealthPlanExpiry:   d.HealthPlanExpiry,
		HealthPlanType:     (*vos.HealthPlanType)(d.HealthPlanType),
	}
}
