// Package schemas holds the explicit TableSchemas that partition the flat Go
// entities across their physical tables. Schemas are reusable — one per file —
// so a single declaration (e.g. AddressSchema) serves every aggregate that
// embeds it (both User and Employee reference the same Person base and its
// addresses).
//
// This service exercises the framework's relational-specialization features.
// The Go entities (*appdomain.User, *appdomain.Employee) stay flat and
// single; the TableSchemas here are the ONLY place that partitions their
// fields across the physical tables:
//
//	persons             — SharedBase (Party-Role identity), natural key = document,
//	                      id = UUIDv5(document). Holds the shared Person fields
//	                      (document/name/email/phone) and OWNS the addresses.
//	                      Referenced by BOTH roles (users + employees).
//	addresses           — base-child of persons (FK person_id, 1:N). The address
//	                      list is the person's, shared by every role of that person.
//	users               — the User role root (shared PK: users.id == persons.id),
//	                      carrying the one role-private field (user_name).
//	user_configurations — Sibling of users (1:1, shares the user PK): the
//	                      notification preference flags.
//	employees        — the Employee role root (shared PK too), carrying
//	                      employee_number; owns the two role children below plus the
//	                      bank-account sibling.
//	employee_bank_accounts  — Sibling of employees (1:1, shared PK).
//	employee_dependents      — role-owned child of employees (FK
//	                               employee_id, 1:N); carries its own sibling.
//	dependent_health_plans       — Sibling of employee_dependents (1:1 on the
//	                               child PK) — the child-level (A2b) sibling.
//	employee_job_histories — second role-owned child (FK employee_id, 1:N).
//
// domain/application/web never see any of this — they speak the flat entities.
// The schema graph is what the write path, the criteria engine, the auto-scan
// read-back, and the Mongo composer all consult.
package schemas

import (
	"github.com/ClaudioSchirmer/omnicore/infra/db/core"
)

// PersonBase is the SharedBase: the deduplicated Person identity. Document is
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
// CreatedAt/UpdatedAt on the base are honored by the framework like on any
// other table: stamped on the identity's creation, and UpdatedAt on every
// role-driven change of the shared fields (warm upsert + role update) — so
// persons.updated_at tells the truth even when the change came in through a
// role endpoint.
func PersonBase() *core.TableSchema {
	return core.NewSharedBase("persons").
		PK("id").
		Field("Document", "document").
		Field("Name", "name").
		Field("Email", "email").
		Field("Phone", "phone").
		NaturalKey("document").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at").
		OrphanPolicy(core.DeleteWhenUnreferenced).
		Child(AddressSchema())
}
