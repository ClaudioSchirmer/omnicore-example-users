package schemas

import (
	"github.com/ClaudioSchirmer/omnicore/infra/db/core"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// AddressSchema is the base-child schema for the addresses table — declared once
// and reused as the SharedBase's child (PersonBase().Child(...)) and as the view
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
