package domain

import "github.com/ClaudioSchirmer/omnicore/domain"

// Notifications specific to the User aggregate.
// Each struct embeds DomainNotificationBase so reflect.TypeOf(...).Name()
// becomes the translation key (e.g. "InvalidEmailNotification").

type InvalidEmailNotification struct{ domain.DomainNotificationBase }
type InvalidPhoneNotification struct{ domain.DomainNotificationBase }
type InvalidDocumentNotification struct{ domain.DomainNotificationBase }

type InvalidStateNotification struct{ domain.DomainNotificationBase }
type InvalidZipCodeNotification struct{ domain.DomainNotificationBase }
type InvalidCountryNotification struct{ domain.DomainNotificationBase }

// DocumentCannotChangeNotification is the canonical transition-aware invariant
// of this example: Document is the shared Person identity's natural key, so it
// is immutable once the user is created. Fired by User.BuildRules inside
// r.IfUpdate when domain.Old(u).Document differs from u.Document. Default
// Semantic (Validation → 422) — the wire field carries the rejected value to
// make it visible to the consumer.
//
// Showcases domain.Old[T]: the framework's Get* path stores the loaded entity
// as a typed read-only ghost before applying any mutation, so the comparison
// "old vs new" inside BuildRules works the same on PUT and PATCH.
type DocumentCannotChangeNotification struct{ domain.DomainNotificationBase }

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
// The MaxLength field is set directly inside User.BuildRules from the
// package-private domain constant nameMaxLength (domain/user.go) when
// len(u.Name) overflows it. The example hardcodes 100; production would resolve
// it from a per-tenant config service consulted via a domain.Service inside
// BuildRules — same notification type, same wire shape, only the source of the
// value changes.
type NameMaxLengthExceededNotification struct {
	domain.DomainNotificationBase
	MaxLength int `tvar:"maxLength"`
}
