package infra

import (
	"github.com/ClaudioSchirmer/omnicore/infra/db/core"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// UserSchema is the single explicit Go-field↔physical-column map for the User
// aggregate — the mandatory TableSchema that replaces convention/inference. It
// is the one declaration that feeds the write path, the criteria engine, and
// the auto-scan read-back; the read-side ViewDefinition reuses the same root +
// child schemas so write and read agree on every name.
//
// Every persisted field is declared explicitly: Go name on one side, DB column
// on the other. The runtime-only authz fields on *User (RequestingPrincipalEmail,
// RequestingPrincipalIsAdmin) are simply NOT declared here — an undeclared
// exported field is never persisted, scanned, or audited. No tag, no
// convention, no guessing.
//
// Managed columns: deleted_at (soft-delete predicate), created_at + updated_at
// (framework-stamped NOW() on write). The framework never relies on a DB
// DEFAULT it does not own.
func UserSchema() *core.TableSchema {
	return core.NewTableSchema[*appdomain.User]("users").
		PK("id").
		Field("Name", "name").
		Field("Email", "email").
		Field("Phone", "phone").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at").
		Child(AddressSchema())
}

// AddressSchema is the child schema for the addresses table — declared once and
// reused both as the aggregate child (UserSchema().Child(...)) and as the view
// embed source schema (so the Mongo reader translates the embed's leaf fields
// between Go names and physical columns). The FK column referencing the root is
// declared via FK; it is injected by the persister and is not a struct field.
func AddressSchema() *core.TableSchema {
	return core.NewTableSchema[appdomain.Address]("addresses").
		PK("id").
		FK("user_id").
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
