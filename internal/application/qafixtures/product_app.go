//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// ─── Commands (Auto path — no hooks; the Product fixture is about rules) ────

// InsertProductCommand is the application-layer "create Product" use case,
// handled by the Auto InsertCommandHandler with the ProductService injected —
// which is how the grouped-facts rule (max 3 distinct categories) fires.
type InsertProductCommand struct {
	pipeline.CommandWithBodyBase
	Code       string
	Category   string
	PriceCents int64
	Weight     float64
}

func (c *InsertProductCommand) ToEntity(_ *configuration.AppContext) (*qadomain.Product, error) {
	return &qadomain.Product{
		Code:       c.Code,
		Category:   c.Category,
		PriceCents: c.PriceCents,
		Weight:     c.Weight,
	}, nil
}

func (c *InsertProductCommand) FromEntity(_ *configuration.AppContext, p *qadomain.Product) (InsertProductResult, error) {
	return InsertProductResult{
		ID:         *p.GetID(),
		Code:       p.Code,
		Category:   p.Category,
		PriceCents: p.PriceCents,
		Weight:     p.Weight,
	}, nil
}

// InsertProductResult is the application-layer projection returned by FromEntity.
type InsertProductResult struct {
	ID         domain.ID
	Code       string
	Category   string
	PriceCents int64
	Weight     float64
}

var _ pipeline.InsertCommand[*qadomain.Product, InsertProductResult] = (*InsertProductCommand)(nil)

// ArchiveProductCommand / UnarchiveProductCommand — the soft-delete pair, so
// QA can prove archived rows fold out of (and back into) the grouped facts.
type ArchiveProductCommand struct{ pipeline.CommandByIDBase }

func (*ArchiveProductCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.Product) error {
	return nil
}

func (*ArchiveProductCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.Product) (fwresults.None, error) {
	return fwresults.None{}, nil
}

type UnarchiveProductCommand struct{ pipeline.CommandByIDBase }

func (*UnarchiveProductCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.Product) error {
	return nil
}

func (*UnarchiveProductCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.Product) (fwresults.None, error) {
	return fwresults.None{}, nil
}

// ─── Stats read port (the /qa/products/stats surface) ───────────────────────

// ProductScalarStats is one row of scalar facts — the full spec vocabulary
// over PriceCents (exact int64) and Weight (float64). Found mirrors the DSL's
// flag for the facts that are NULL on an empty set.
type ProductScalarStats struct {
	Count      int64
	SumCents   int64
	MinCents   int64
	MaxCents   int64
	AvgWeight  float64
	SumWeight  float64
	MinWeight  float64
	MaxWeight  float64
	FactsFound bool
}

// ProductCategoryStats is ProductScalarStats keyed by its GROUP BY category.
type ProductCategoryStats struct {
	Category string
	ProductScalarStats
}

// ProductStatsResult is the whole stats read: the ungrouped facts (ONE
// Aggregate SELECT) plus the per-category facts (ONE AggregateBy SELECT),
// categories ordered by key ascending — the DSL's deterministic order.
type ProductStatsResult struct {
	Global     ProductScalarStats
	Categories []ProductCategoryStats
}

// ProductStatsReader is the application port behind GET /qa/products/stats.
// Implemented in infra over Aggregate + AggregateBy; includeArchived maps to
// the criteria's IncludeArchived scope so QA can watch the scope gate work.
type ProductStatsReader interface {
	Stats(ctx *configuration.AppContext, includeArchived bool) (*ProductStatsResult, error)
}
