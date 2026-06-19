package infra

import (
	fwinfra "github.com/ClaudioSchirmer/omnicore/infra"
)

// UserView is the read-side projection of the User aggregate for MongoDB.
//
//   - Mongo collection / root table = "users"
//   - EmbedMany of Address under the doc field "addresses" (table "addresses",
//     join key "user_id"); the parent-side Go segment is "Addresses" (.As) so
//     the reader translates the embed back to the Go field name the typed
//     Response refers to.
//
// The view reuses the SAME schemas the repository declares — UserSchema() for
// the root and AddressSchema() for the embed source. The composer writes
// physical columns (mail/zip_code/...) to Mongo; the reader translates each leaf
// back to its Go field name (Email/ZipCode/...) using these schemas, so the wire
// surface speaks Go names while Mongo mirrors PostgreSQL physically. The view
// also honors the schema's soft-delete column when DeleteOnArchive is set.
//
// On ARCHIVED/DELETED events the doc is removed; on UNARCHIVED it is
// recomposed and re-upserted (SyncEngine logic, applicable to any
// ViewDefinition).
//
// The view declares the indexes the read-side endpoints rely on at
// runtime. The TextIndex over (name, email) is the artifact MongoDB
// requires for the framework's `?search=` parameter — without it the
// driver returns error code 27 ("text index required for $text query")
// on the first request. `bootstrap.Run` materializes every index via
// `fwinfra.ApplyMongoSpecs` between `collectViews` and SyncEngine.Start;
// idempotent on steady state, strict on divergence.
//
// Called exactly once per process via bootstrap.NewUsersFeature.
func UserView() *fwinfra.ViewDefinition {
	return fwinfra.View("users").
		Version(1).
		Root("users").
		Schema(UserSchema()).
		EmbedMany("addresses", fwinfra.FromSchema(AddressSchema())).
		Indexes(
			fwinfra.Index("email"),
			fwinfra.Index("created_at").Desc(),
			fwinfra.TextIndex("name", "email").DefaultLanguage("english"),
		)
}
