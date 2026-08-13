package aggregatevos

import (
	"time"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/vos"
	"github.com/ClaudioSchirmer/omnicore/domain"
)

// Dependent is a role-owned AggregateValueObject of Employee (table
// employee_dependents, ParentID employee_id — declared in infra/schema.go).
// It is the child that carries a SIBLING (the A2b path): the health-plan
// fields below live in the dependent_health_plans table, 1:1 on the child's
// own ID, materialized only when at least one of them is non-nil.
//
// Value type (not pointer) so the framework's typed primitives track it by
// value; identity for that tracking is IsSameBusinessIdentity — as with Address.
type Dependent struct {
	domain.Managed
	Name         string           `labelKey:"DependentNameField"`
	BirthDate    time.Time        `labelKey:"DependentBirthDateField"`
	Relationship vos.Relationship `labelKey:"DependentRelationshipField"`

	// ─── Child-level sibling: health plan (dependent_health_plans, 1:1) ────
	// nil = no plan row. Same conditional-materialization semantics as the
	// role's bank-account sibling, one level down the aggregate.
	HealthPlanProvider *string             `labelKey:"DependentHealthPlanProviderField"`
	HealthPlanCard     *vos.HealthPlanCard `labelKey:"DependentHealthPlanCardField"`
	HealthPlanExpiry   *time.Time          `labelKey:"DependentHealthPlanExpiryField"`
	HealthPlanType     *vos.HealthPlanType `labelKey:"DependentHealthPlanTypeField"` // child-sibling enum
}

// IsSameBusinessIdentity is the framework-required identity for change tracking
// (replacing the former reflect.DeepEqual guess). A Dependent has no natural key
// narrower than its full value, so it delegates to IsSameByBusinessFields.
func (d Dependent) IsSameBusinessIdentity(other domain.AggregateValueObject) bool {
	return domain.IsSameByBusinessFields(d, other)
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
		// Relationship (enum) and the nullable child-sibling VOs (HealthPlanCard,
		// HealthPlanType) are value objects — the framework discovers and validates
		// them off the struct (nil pointers skipped); nothing to wire here.
	})
}

// CollectionName — see Address.CollectionName. This one nests inside the
// employee role document.
func (Dependent) CollectionName() string { return "Dependents" }
