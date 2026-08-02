// Package views holds the read-side Mongo view definitions, one per file. Each
// view imports the reusable TableSchemas from the schemas sub-package so the
// composer (physical columns into Mongo) and the reader (translate each leaf
// back to its Go field name) agree on every name across write and read.
package views

import (
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/infra/schemas"
)

// UserView is the read-side projection of the User aggregate for MongoDB.
//
//   - Mongo collection / root table = "users" (the role).
//   - The shared Person fields (document/name/email/phone) are merged FLAT into
//     the user doc by the composer (SharedBase), and the notification sibling
//     fields (email_notification/sms_notification) likewise — the doc mirrors the
//     flat Go entity, so the read surface is unchanged in shape from a plain
//     aggregate.
//   - The addresses are the BASE's native children: the composer nests them
//     under the derived "Addresses" segment automatically (ParentID person_id), so
//     there is NO explicit EmbedMany here — declaring the SharedBase with its
//     Child(AddressSchema()) is sufficient and the view derives the embed.
//
// The view reuses the SAME schema the repository declares — schemas.UserSchema() —
// so the composer (physical columns into Mongo) and the reader (translate each leaf
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
		Schema(schemas.UserSchema()).
		Indexes(
			query.Index("document"),
			query.Index("email"),
			query.Index("created_at").Desc(),
			query.TextIndex("name", "email").DefaultLanguage("english"),
		)
}

// UserRelView is the RelationalSource twin of UserView — the SAME User aggregate,
// but served straight from the relational SoR (read-your-writes, no CDC) instead
// of the Mongo projection. It is the canonical demonstration of RelationalSource
// AND the read side of the SQLite MVP (which has no CDC, so a Mongo view never
// materializes — the relational view is its only read path).
//
// Because User is a shared-base role with a sibling, this one view exercises the
// full 1:1 reach of the relational reader: the root (userName), the Person shared
// base (name/email/document/phone) and the user_configurations sibling
// (emailNotification/smsNotification) are all filterable/sortable — the loader
// LEFT JOINs the base and the sibling in. Only the addresses (1:N base children)
// are out of reach (→ 400), the same rule the Mongo twin does not share.
//
// It reuses the aggregate's existing loader (one loader per aggregate, passed in
// from the repository) — the boot guard checks it is bound to the users table.
func UserRelView(loader query.RelationalReader) *query.ViewDefinition {
	return query.View("users_rel").
		Version(1).
		Schema(schemas.UserSchema()).
		RelationalSource(loader)
}
