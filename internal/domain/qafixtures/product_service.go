//go:build qa

package qafixtures

import "github.com/ClaudioSchirmer/omnicore/domain"

// The Product domain service — its own file per the service-layout standard:
// the PORT (interface) lives with its consumer (this package); the
// implementation lives in internal/infra/qafixtures/product_service.go.

// ProductCategoryFact is one per-category scalar fact the stats port answers
// with — pure data, produced by the infra adapter from ONE grouped SELECT.
type ProductCategoryFact struct {
	Category string
	Count    int64
}

// ProductStats is the domain port answering "how are the ACTIVE products
// distributed across categories?". Implemented in infra over the framework's
// grouped aggregate DSL (AggregateBy); the domain sees only pure facts.
type ProductStats interface {
	ActiveCategoryFacts() ([]ProductCategoryFact, error)
}

// ProductService carries the stats port into BuildRules — the canonical
// domain.Service shape: a struct embedding ServiceBase with the capabilities
// the rules consume. Product.RequiresService() makes its injection mandatory
// on every verb.
type ProductService struct {
	domain.ServiceBase
	Stats ProductStats
}
