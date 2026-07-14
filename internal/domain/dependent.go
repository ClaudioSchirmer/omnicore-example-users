package domain

import (
	"time"

	"github.com/ClaudioSchirmer/omnicore/domain"
)

// Dependent is a role-owned AggregateValueObject of Employee (table
// employee_dependents, FK employee_id — declared in infra/schema.go).
// It is the child that carries a SIBLING (the A2b path): the health-plan
// fields below live in the dependent_health_plans table, 1:1 on the child's
// own PK, materialized only when at least one of them is non-nil.
//
// Value type (not pointer) so reflect.DeepEqual inside the framework's typed
// primitives compares by field equality — same convention as Address.
type Dependent struct {
	ID           domain.ID
	Name         string    `labelKey:"DependentNameField"`
	BirthDate    time.Time `labelKey:"DependentBirthDateField"`
	Relationship string    `labelKey:"DependentRelationshipField"`

	// ─── Child-level sibling: health plan (dependent_health_plans, 1:1) ────
	// nil = no plan row. Same conditional-materialization semantics as the
	// role's bank-account sibling, one level down the aggregate.
	HealthPlanProvider *string    `labelKey:"DependentHealthPlanProviderField"`
	HealthPlanCard     *string    `labelKey:"DependentHealthPlanCardField"`
	HealthPlanExpiry   *time.Time `labelKey:"DependentHealthPlanExpiryField"`
}

func (d Dependent) GetID() domain.ID { return d.ID }

// knownRelationships is the closed set the Relationship field accepts — a
// pure domain rule of this aggregate (lowercase canonical form; the wire
// sends it verbatim).
var knownRelationships = map[string]bool{
	"spouse":   true,
	"son":      true,
	"daughter": true,
	"father":   true,
	"mother":   true,
	"other":    true,
}

// BuildRules fires at the boundary (GetInsertable/GetUpdatable/...) via the
// framework's runAggregateValidations, with the *Rules already scoped at
// dependents[i] — same lifecycle as Address.BuildRules.
func (d Dependent) BuildRules(actionName string, service domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if d.Name == "" {
			r.AddNotification("Name", domain.RequiredFieldNotification{})
		}
		if d.BirthDate.IsZero() {
			r.AddNotification("BirthDate", domain.RequiredFieldNotification{})
		}
		if d.Relationship == "" {
			r.AddNotification("Relationship", domain.RequiredFieldNotification{})
		} else if !knownRelationships[d.Relationship] {
			r.AddNotification("Relationship", InvalidRelationshipNotification{}, d.Relationship)
		}
	})
}
