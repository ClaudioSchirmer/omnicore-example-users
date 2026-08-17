//go:build qa

package qafixtures

import "github.com/ClaudioSchirmer/omnicore/domain"

// ProductCategoryLimitNotification is emitted by Product.BuildRules when an
// insert would create a distinct active category beyond the closed cap — the
// grouped-facts invariant (the fact list comes from the framework's
// AggregateBy through the ProductService port). Default Semantic (Validation →
// 422); the wire value echoes the rejected category. Its translation entries
// live in the canonical catalogs (internal/application/translations) — the
// keys are plain data, so they do not leak qa code into canonical builds.
type ProductCategoryLimitNotification struct{ domain.DomainNotificationBase }

// ─── the composite-value-object family ───────────────────────────────────────

// UnknownCurrencyNotification is the enum value object Currency's out-of-set
// notification — emitted by the framework's membership check when the value is
// the Unknown sentinel (a tampered or legacy row converges there on read).
type UnknownCurrencyNotification struct{ domain.DomainNotificationBase }

// NegativeAmountNotification is emitted by Money.IsValid — a rule owned by the
// composite value object itself, on one of its parts.
type NegativeAmountNotification struct{ domain.DomainNotificationBase }

// PeriodEndsBeforeStartNotification is emitted by Period.IsValid: the CROSS-FIELD
// rule that only a composite value object can express, since neither of its two
// fields can judge it alone.
type PeriodEndsBeforeStartNotification struct{ domain.DomainNotificationBase }

// CurrencyIsImmutableNotification is emitted by Contract.BuildRules from the
// Old() ghost — a transition rule reading a composite value object across the
// pre-write snapshot.
type CurrencyIsImmutableNotification struct{ domain.DomainNotificationBase }
