package infra

import "github.com/ClaudioSchirmer/omnicore/infra/db/query"

// UserView is the read-side projection of the User aggregate for MongoDB.
//
//   - Mongo collection / root table = "users" (the role).
//   - The shared Person fields (document/name/email/phone) are merged FLAT into
//     the user doc by the composer (SharedBase), and the notification sibling
//     fields (email_notification/sms_notification) likewise — the doc mirrors the
//     flat Go entity, so the read surface is unchanged in shape from a plain
//     aggregate.
//   - The addresses are the BASE's native children: the composer nests them
//     under the derived "Addresses" segment automatically (FK person_id), so
//     there is NO explicit EmbedMany here — declaring the SharedBase with its
//     Child(AddressSchema()) is sufficient and the view derives the embed.
//
// The view reuses the SAME schema the repository declares — UserSchema() — so
// the composer (physical columns into Mongo) and the reader (translate each leaf
// back to its Go field name) agree on every name across write and read.
//
// On ARCHIVED/DELETED events the doc is removed; on UNARCHIVED it is recomposed
// and re-upserted. A change to a shared Person field or address via the role
// fans out: the base write emits an extra outbox event for persons, the
// SyncEngine recomposes every role doc of that person (here, the single user).
//
// Indexes the read-side endpoints rely on: document (the natural-key lookup that
// replaces email as the manual-showcase handle), email, created_at (sort), and a
// TextIndex over (name, email) for the framework's `?search=` parameter. All are
// physical columns present at the root of the stored doc (the base fields land
// flat). `bootstrap.Run` materializes every index via `fwinfra.ApplyMongoSpecs`.
//
// Called exactly once per process via bootstrap.NewUsersFeature.
func UserView() *query.ViewDefinition {
	return query.View("users").
		Version(1).
		Root("users").
		Schema(UserSchema()).
		Indexes(
			query.Index("document"),
			query.Index("email"),
			query.Index("created_at").Desc(),
			query.TextIndex("name", "email").DefaultLanguage("english"),
		)
}

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
		Schema(EmployeeSchema()).
		Indexes(
			query.Index("document"),
			query.Index("employee_number"),
			query.Index("created_at").Desc(),
			query.TextIndex("name", "email").DefaultLanguage("english"),
		)
}
