package infra

import (
	fwinfra "github.com/ClaudioSchirmer/omnicore/infra"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// UserView is the read-side projection of the User aggregate for MongoDB.
//
// Inferred from the Go type:
//   - Mongo collection / root table = "users" (InferTableName(User))
//   - EmbedMany of Address auto-registered via User.AggregateChildren():
//     field "addresses" + table "addresses" + FK "user_id"
//
// Equivalent to the verbose fluent form:
//
//	fwinfra.View("users").Root("users").
//	    EmbedMany("addresses", fwinfra.From("addresses").On("user_id"))
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
	return fwinfra.ViewOf[*appdomain.User]().
		Version(1).
		Indexes(
			fwinfra.Index("email"),
			fwinfra.Index("created_at").Desc(),
			fwinfra.TextIndex("name", "email").DefaultLanguage("portuguese"),
		)
}
