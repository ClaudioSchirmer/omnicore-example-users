package schemas

import (
	"github.com/ClaudioSchirmer/omnicore/infra/db/core"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// EmployeeSchema is the SECOND role over the SAME Person base — the
// layer-6 exercise: it reuses PersonBase() as-is, so a User and a Employee
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
		Revision("revision").
		SharedBase(PersonBase(), "id").
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
