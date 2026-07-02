package infra

import (
	"github.com/ClaudioSchirmer/omnicore/infra/db/core"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// This service exercises the framework's relational-specialization features.
// The Go entities (*appdomain.User, *appdomain.Employee) stay flat and
// single; the TableSchemas below are the ONLY place that partitions their
// fields across the physical tables:
//
//   persons             — SharedBase (Party-Role identity), natural key = document,
//                         id = UUIDv5(document). Holds the shared Person fields
//                         (document/name/email/phone) and OWNS the addresses.
//                         Referenced by BOTH roles (users + employees).
//   addresses           — base-child of persons (FK person_id, 1:N). The address
//                         list is the person's, shared by every role of that person.
//   users               — the User role root (shared PK: users.id == persons.id),
//                         carrying the one role-private field (user_name).
//   user_configurations — Sibling of users (1:1, shares the user PK): the
//                         notification preference flags.
//   employees        — the Employee role root (shared PK too), carrying
//                         employee_number; owns the two role children below plus the
//                         bank-account sibling.
//   employee_bank_accounts  — Sibling of employees (1:1, shared PK).
//   employee_dependents      — role-owned child of employees (FK
//                                  employee_id, 1:N); carries its own sibling.
//   dependent_health_plans       — Sibling of employee_dependents (1:1 on the
//                                  child PK) — the child-level (A2b) sibling.
//   employee_job_histories — second role-owned child (FK employee_id, 1:N).
//
// domain/application/web never see any of this — they speak the flat entities.
// The schema graph is what the write path, the criteria engine, the auto-scan
// read-back, and the Mongo composer all consult.

// UserSchema is the ROLE schema (the aggregate the app creates). It references
// the shared Person base and declares the role-private user_name plus the
// notification sibling. It does NOT declare .Child(AddressSchema()) — the
// addresses belong to the BASE, and the framework unions the base's children
// into the role's effective aggregate (EffectiveChildNames), so the flat
// User.Addresses collection is materialized against persons (FK person_id).
//
// Each call builds a fresh, self-contained schema graph (role + its own Person
// base instance + addresses). There is exactly one role, so no second role has
// to share the base instance; the single-call graph satisfies the framework's
// "one base instance per identity" invariant on its own.
func UserSchema() *core.TableSchema {
	return core.NewTableSchema[*appdomain.User]("users").
		PK("id").
		SharedBase(personBase(), "id").
		Field("UserName", "user_name").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at").
		Sibling(core.NewSiblingSchema[*appdomain.User]("user_configurations").
			Field("EmailNotification", "email_notification").
			Field("SmsNotification", "sms_notification"))
}

// personBase is the SharedBase: the deduplicated Person identity. Document is
// the natural key — the framework derives the deterministic id UUIDv5(document)
// from it (no read-back) and de-duplicates on it. SoftDelete on the base is the
// recommended unified-lifecycle path: the base behaves as a mini-root over its
// addresses, archived/unarchived/deleted in lock-step with its role via the
// framework's convergeBase (so the addresses are gated by deleted_at exactly
// like every other table). OrphanPolicy(DeleteWhenUnreferenced) hard-deletes
// the person (and its addresses) once the last user row referencing it is gone.
//
// Addresses are declared HERE as the base's native children (FK person_id), not
// on the role — that is what makes the address list shared across every role of
// the person rather than disjoint per role.
func personBase() *core.TableSchema {
	return core.NewSharedBase("persons").
		PK("id").
		Field("Document", "document").
		Field("Name", "name").
		Field("Email", "email").
		Field("Phone", "phone").
		NaturalKey("document").
		SoftDelete("deleted_at").
		OrphanPolicy(core.DeleteWhenUnreferenced).
		Child(AddressSchema())
}

// EmployeeSchema is the SECOND role over the SAME Person base — the
// layer-6 exercise: it reuses personBase() as-is, so a User and a Employee
// created with the same document resolve to ONE persons row (refcount 2), and
// hard-deleting one role keeps the base alive for the other. Also the shared-PK
// model (employees.id == persons.id).
//
// Unlike UserSchema it declares role-owned CHILDREN of its own —
// Dependent (which carries the child-level A2b sibling) and JobHistory —
// hung on the ROLE schema, so they are private to the Employee; the shared
// Addresses keep coming from the base's Child(AddressSchema()).
func EmployeeSchema() *core.TableSchema {
	return core.NewTableSchema[*appdomain.Employee]("employees").
		PK("id").
		SharedBase(personBase(), "id").
		Field("EmployeeNumber", "employee_number").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at").
		Sibling(core.NewSiblingSchema[*appdomain.Employee]("employee_bank_accounts").
			Field("Bank", "bank").
			Field("Branch", "branch").
			Field("Account", "account").
			Field("Pix", "pix")).
		Child(DependentSchema()).
		Child(JobHistorySchema())
}

// DependentSchema is a ROLE-owned child (FK employee_id → the role id, not
// the person id) that itself carries a SIBLING — the A2b path: the health-plan
// facet lives in dependent_health_plans, 1:1 on the child's own PK,
// materialized only when at least one plan field is non-nil.
func DependentSchema() *core.TableSchema {
	return core.NewTableSchema[appdomain.Dependent]("employee_dependents").
		PK("id").
		FK("employee_id").
		Field("Name", "name").
		Field("BirthDate", "birth_date").
		Field("Relationship", "relationship").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at").
		Sibling(core.NewSiblingSchema[appdomain.Dependent]("dependent_health_plans").
			Field("HealthPlanProvider", "provider").
			Field("HealthPlanCard", "card").
			Field("HealthPlanExpiry", "expires_at"))
}

// JobHistorySchema is the SECOND role-owned child — plain (no sibling),
// present so the role dispatches more than one child collection of its own.
func JobHistorySchema() *core.TableSchema {
	return core.NewTableSchema[appdomain.JobHistory]("employee_job_histories").
		PK("id").
		FK("employee_id").
		Field("JobTitle", "job_title").
		Field("Department", "department").
		Field("HiredAt", "hired_at").
		Field("TerminatedAt", "terminated_at").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}

// AddressSchema is the base-child schema for the addresses table — declared once
// and reused as the SharedBase's child (personBase().Child(...)) and as the view
// composes it automatically. The FK references the BASE's deterministic id
// (person_id), not the role id; the persister injects it, so it is not a struct
// field. Soft-delete on the base-child is permitted because the base itself
// carries soft-delete (all-or-nothing per base).
func AddressSchema() *core.TableSchema {
	return core.NewTableSchema[appdomain.Address]("addresses").
		PK("id").
		FK("person_id").
		Field("Label", "label").
		Field("Street", "street").
		Field("Number", "number").
		Field("Complement", "complement").
		Field("Neighborhood", "neighborhood").
		Field("City", "city").
		Field("State", "state").
		Field("ZipCode", "zip_code").
		Field("Country", "country").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}
