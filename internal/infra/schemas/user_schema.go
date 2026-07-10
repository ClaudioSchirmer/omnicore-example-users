package schemas

import (
	"github.com/ClaudioSchirmer/omnicore/infra/db/core"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

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
		SharedBase(PersonBase(), "id").
		Field("UserName", "user_name").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at").
		Sibling(core.NewSiblingSchema[*appdomain.User]("user_configurations").
			Field("EmailNotification", "email_notification").
			Field("SmsNotification", "sms_notification"))
}
