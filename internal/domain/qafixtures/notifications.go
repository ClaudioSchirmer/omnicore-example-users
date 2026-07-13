//go:build qa

package qafixtures

import "github.com/ClaudioSchirmer/omnicore/domain"

// ProductCategoryLimitNotification is emitted by Product.BuildRules when an
// insert would create a distinct active category beyond the closed cap — the
// grouped-facts invariant (the fact list comes from the framework's
// AggregateBy through the ProductStats port). Default Semantic (Validation →
// 422); the wire value echoes the rejected category. Its translation entries
// live in the canonical catalogs (internal/application/translations) — the
// keys are plain data, so they do not leak qa code into canonical builds.
type ProductCategoryLimitNotification struct{ domain.DomainNotificationBase }
