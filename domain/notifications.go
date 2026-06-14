package domain

import "github.com/ClaudioSchirmer/omnicore/domain"

// Notifications specific to the User aggregate.
// Each struct embeds DomainNotificationBase so reflect.TypeOf(...).Name()
// becomes the translation key (e.g. "InvalidEmailNotification").

type InvalidEmailNotification struct{ domain.DomainNotificationBase }
type InvalidPhoneNotification struct{ domain.DomainNotificationBase }

type InvalidStateNotification struct{ domain.DomainNotificationBase }
type InvalidZipCodeNotification struct{ domain.DomainNotificationBase }
type InvalidCountryNotification struct{ domain.DomainNotificationBase }

// Raised by the repository when a UNIQUE constraint violation comes back
// from Postgres on the email column. Semantic() override is required so the
// framework maps this to 409 Conflict instead of the default 422.
type EmailAlreadyExistsNotification struct{ domain.DomainNotificationBase }

func (EmailAlreadyExistsNotification) Semantic() domain.NotificationSemantic {
	return domain.SemanticConflict
}

// EmailCannotChangeNotification is the canonical transition-aware invariant
// of this example: once a User is created, the email is immutable. Fired by
// User.BuildRules inside r.IfUpdate when domain.Old(u).Email differs from
// u.Email. Default Semantic (Validation → 422) — the wire field carries the
// rejected value to make it visible to the consumer.
//
// Showcases domain.Old[T]: the framework's Get* path stores the loaded
// entity as a typed read-only ghost before applying any mutation, so the
// comparison "old vs new" inside BuildRules works the same on PUT and PATCH.
type EmailCannotChangeNotification struct{ domain.DomainNotificationBase }

// DuplicateAddressNotification is emitted by User.AddAddress when the incoming
// address has the same business identity as one already in the aggregate. Phase
// 20: aggregate invariants spanning children live in domain methods on the
// root, not in the framework's primitives. Default Semantic (Validation → 422)
// fits "this batch carries a duplicate" — Conflict (409) would also be
// defensible if the source of truth were the existing collection rather than
// the request shape.
type DuplicateAddressNotification struct{ domain.DomainNotificationBase }

// NameMaxLengthExceededNotification is the canonical parameterized-notification
// showcase of this service. The MaxLength field carries the per-request limit
// the rule rejected; the framework's translation layer reflects the `tvar`
// tag and substitutes {maxLength} in the catalog string at render time.
//
// Default Semantic (Validation → 422). Wire envelope carries the rejected
// input via the AddNotification value parameter, mirroring InvalidEmail /
// InvalidPhone shape — the consumer sees both "what they sent" (value) and
// "what the limit is" (substituted into the message).
//
// The MaxLength field is populated by the Cmd boundary
// (InsertUserCommand.ToEntity / UpdateUserCommand.ApplyTo /
// PatchUserCommand.ApplyPartiallyTo and their manual showcase twins) and
// flows into User.NameMaxLength as a transient:"-" field. The example
// hardcodes 100 at the Cmd boundary; production would resolve it from a
// per-tenant config service.
type NameMaxLengthExceededNotification struct {
	domain.DomainNotificationBase
	MaxLength int `tvar:"maxLength"`
}
