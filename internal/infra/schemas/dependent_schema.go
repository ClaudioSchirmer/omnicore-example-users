package schemas

import (
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/aggregatevos"
	"github.com/ClaudioSchirmer/omnicore/infra/db/core"
)

// DependentSchema is a ROLE-owned child (ParentID employee_id → the role id, not
// the person id) that itself carries a SIBLING — the A2b path: the health-plan
// facet lives in dependent_health_plans, 1:1 on the child's own ID,
// materialized only when at least one plan field is non-nil.
func DependentSchema() *core.TableSchema {
	return core.NewTableSchema[aggregatevos.Dependent]("employee_dependents").
		ID("id").
		ParentID("employee_id").
		Field("Name", "name").
		Field("BirthDate", "birth_date").
		Field("Relationship", "relationship").
		DeletedAt("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at").
		Sibling(core.NewSiblingSchema[aggregatevos.Dependent]("dependent_health_plans").
			Field("HealthPlanProvider", "provider").
			Field("HealthPlanCard", "card").
			Field("HealthPlanExpiry", "expires_at").
			Field("HealthPlanType", "health_plan_type")) // enum value object (string-backed) on a CHILD-level sibling
}
