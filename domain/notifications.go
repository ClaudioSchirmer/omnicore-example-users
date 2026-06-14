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
