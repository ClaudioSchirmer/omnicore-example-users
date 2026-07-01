package infra

import (
	"github.com/ClaudioSchirmer/omnicore/infra/db/core"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// This service exercises the framework's relational-specialization features.
// The Go entity (*appdomain.User) stays flat and single; the TableSchema below
// is the ONLY place that partitions its fields across four physical tables:
//
//   persons             — SharedBase (Party-Role identity), natural key = document,
//                         id = UUIDv5(document). Holds the shared Person fields
//                         (document/name/email/phone) and OWNS the addresses.
//   addresses           — base-child of persons (FK person_id, 1:N). The address
//                         list is the person's, shared by every role of that person.
//   users               — the role/anchor root (shared PK: users.id == persons.id),
//                         carrying the one role-private field (user_name).
//   user_configurations — Sibling of users (1:1, shares the user PK): the
//                         notification preference flags.
//
// domain/application/web never see any of this — they speak the flat User. The
// schema graph is what the write path, the criteria engine, the auto-scan
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
