package views

import (
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/infra/schemas"
)

// EmployeeView is the read-side projection of the Employee aggregate.
// Same declarative recipe as UserView — the schema alone materializes the
// whole document:
//
//   - the shared Person fields and the bank-account sibling merge FLAT into
//     the root doc;
//   - the base's addresses AND the role's own children (dependents — with
//     their health-plan sibling merged FLAT into each item — and
//     jobHistories) auto-project under their derived pluralized segments,
//     no explicit EmbedMany;
//   - keep-by-default: archived docs survive in the projection (no
//     DeleteOnArchive), gated at read time by ?includeArchived.
//
// A shared-field change through the User role fans out to this view too (the
// persons base event recomposes every role doc of that identity) — the
// cross-role visibility the QA suite asserts.
//
// Called exactly once per process via bootstrap.NewEmployeesFeature.
func EmployeeView() *query.ViewDefinition {
	return query.View("employees").
		Version(1).
		Root("employees").
		Schema(schemas.EmployeeSchema()).
		Indexes(
			query.Index("document"),
			query.Index("employee_number"),
			query.Index("created_at").Desc(),
			query.TextIndex("name", "email").DefaultLanguage("english"),
		)
}
