package requests

import (
	"time"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
)

// DependentRequest is the wire shape of a Dependent inside the Insert/Update
// Employee payloads. Shape mirrors dtos.DependentInput 1:1 — the
// health-plan sibling fields are pointers with omitempty, so an absent plan
// block means nil (no dependent_health_plans row is materialized).
type DependentRequest struct {
	Name         string    `json:"name"       example:"Maria Silva"`
	BirthDate    time.Time `json:"birthDate" example:"2015-03-10T00:00:00Z"`
	Relationship string    `json:"relationship" example:"daughter"`

	HealthPlanProvider *string    `json:"healthPlanProvider,omitempty"     example:"Unimed"`
	HealthPlanCard     *string    `json:"healthPlanCard,omitempty"   example:"UN-889923"`
	HealthPlanExpiry   *time.Time `json:"healthPlanExpiry,omitempty" example:"2027-12-31T00:00:00Z"`
}

// ToDependentInput converts the wire DTO into the application DTO — pure
// assignment, zero normalization.
func (d DependentRequest) ToDependentInput() dtos.DependentInput {
	return dtos.DependentInput{
		Name:               d.Name,
		BirthDate:          d.BirthDate,
		Relationship:       d.Relationship,
		HealthPlanProvider: d.HealthPlanProvider,
		HealthPlanCard:     d.HealthPlanCard,
		HealthPlanExpiry:   d.HealthPlanExpiry,
	}
}
