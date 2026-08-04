//go:build qa

package qafixtures

import "github.com/ClaudioSchirmer/omnicore/domain"

// The Product domain service — its own file per the service-layout standard:
// the interface lives here with its consumer (this package); the implementation
// lives in internal/infra/qafixtures/product_service.go.

// ProductCategoryFact is one per-category scalar fact the service answers with —
// pure data, produced by the infra implementation from ONE grouped SELECT.
type ProductCategoryFact struct {
	Category string
	Count    int64
}

// ProductService is the domain.Service Product.BuildRules consumes: it answers
// "how are the ACTIVE products distributed across categories?" for the
// grouped-facts invariant. It embeds domain.Service (the marker), so BuildRules
// receives it and calls the method directly. The implementation lives in infra
// (ProductServiceImpl) and runs the query under the request context — the domain
// sees only pure facts and never pronounces context. Product.RequiresService()
// makes its injection mandatory on every verb.
type ProductService interface {
	domain.Service
	ActiveCategoryFacts() []ProductCategoryFact
}
