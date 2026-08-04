// Package vos holds the shared value objects — each owning ONE rule reused
// across every role that carries the field (User, Employee, …), so the rule
// lives in one place instead of being copy-pasted into each aggregate's
// BuildRules. Two kinds (see the framework's Value Objects manual section):
//
//   - Raw value objects (Name, Email, Phone, Document, ZipCode, HealthPlanCard)
//     write their own IsValid — the rule is bespoke (a regex, a length cap).
//   - Enum value objects (Ethnicity, AddressType, HealthPlanType,
//     NotificationFrequency, UserProfile, Relationship) declare a closed set:
//     the const block (explicit values) + Values() + an Unknown notification.
//     They do NOT write IsValid — the framework validates membership.
//
// A root's VO fields validate AUTOMATICALLY — the framework discovers VO-typed
// fields and runs each one, so the aggregate registers nothing (use
// IgnoreValueObject in a mode gate to opt one out, or ValidateValueObject to
// force a non-field VO). A child AVO validates an enum inline in its BuildRules
// with domain.ValidateEnum(e, field, ctx). All notifications these value objects emit
// are declared together in notifications.go (this package — the framework's
// domain package imports vos, so they cannot live there). The ROOT owns the
// field LABEL via the `labelKey:"…"` tag; a VO never names a label or a
// translation — it does not decide how a field is presented to a consumer.
package vos
