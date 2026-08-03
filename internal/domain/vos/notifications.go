package vos

import "github.com/ClaudioSchirmer/omnicore/domain"

// Notifications emitted by the value objects in this package. Each embeds
// DomainNotificationBase, so reflect.TypeOf(...).Name() is its translation key
// (e.g. "InvalidEmailNotification"). Default Semantic is Validation → 422; the
// raw VOs echo the rejected input as the wire value.

// ─── Raw value objects (bespoke rule) ───────────────────────────────────────

// InvalidEmailNotification fires when a non-empty email is malformed.
type InvalidEmailNotification struct{ domain.DomainNotificationBase }

// InvalidPhoneNotification fires when a non-empty phone number is malformed.
type InvalidPhoneNotification struct{ domain.DomainNotificationBase }

// InvalidDocumentNotification fires when a non-empty document is malformed.
type InvalidDocumentNotification struct{ domain.DomainNotificationBase }

// InvalidZipCodeNotification fires when a non-empty postal code is malformed.
type InvalidZipCodeNotification struct{ domain.DomainNotificationBase }

// InvalidHealthPlanCardNotification fires when a present card number is malformed.
type InvalidHealthPlanCardNotification struct{ domain.DomainNotificationBase }

// NameMaxLengthExceededNotification is the parameterized-notification showcase:
// MaxLength carries the cap that was exceeded, and the translation layer
// substitutes {maxLength} via the `tvar` tag at render time.
type NameMaxLengthExceededNotification struct {
	domain.DomainNotificationBase
	MaxLength int `tvar:"maxLength"`
}

// ─── Enum value objects (closed set) — the Unknown escape ────────────────────
// Emitted by domain.ValidateEnum when a value falls outside the enum's declared
// set (the zero sentinel or an out-of-range value).

type UnknownEthnicityNotification struct{ domain.DomainNotificationBase }
type UnknownAddressTypeNotification struct{ domain.DomainNotificationBase }
type UnknownHealthPlanTypeNotification struct{ domain.DomainNotificationBase }
type UnknownNotificationFrequencyNotification struct{ domain.DomainNotificationBase }
type UnknownUserProfileNotification struct{ domain.DomainNotificationBase }
type UnknownRelationshipNotification struct{ domain.DomainNotificationBase }
