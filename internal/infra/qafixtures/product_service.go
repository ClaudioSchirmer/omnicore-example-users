//go:build qa

package qafixtures

import (
	"context"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/read"
	"github.com/ClaudioSchirmer/omnicore/infra/db/criteria"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// ProductServiceImpl is the implementation of the domain's ProductService port
// (its own file per the service-layout standard; the interface lives with its
// consumer in internal/domain/qafixtures/product_service.go). It also serves the
// application read port (appqa.ProductStatsReader — the /qa/products/stats read).
// Both ride the SAME loader the repository uses, so schema resolution and the
// scope gate are identical to every other Product access.
//
// Request-context binding: BuildRules is a pure domain method with no context,
// so the grouped-facts probe would otherwise run on context.Background(). The
// impl implements persistence.ScopedServiceProvider — the framework hands it the
// request ctx before BuildRules via ScopedService, which returns a per-request
// shallow copy closing over the ctx. The wired instance is a boot singleton
// (ctx == nil); ActiveCategoryFacts then runs under the request deadline / trace.
type ProductServiceImpl struct {
	domain.ServiceBase
	repo *ProductRepository
	ctx  *configuration.AppContext // nil on the wired singleton; set on the per-request view
}

func NewProductService(repo *ProductRepository) *ProductServiceImpl {
	return &ProductServiceImpl{repo: repo}
}

// ScopedService returns a per-request view closing over ctx — a shallow copy,
// never a mutation of the singleton (shared across concurrent requests). The
// returned value is still a domain.Service.
func (s *ProductServiceImpl) ScopedService(ctx *configuration.AppContext) domain.Service {
	cp := *s
	cp.ctx = ctx
	return &cp
}

// ActiveCategoryFacts answers the domain port with ONE grouped SELECT:
// SELECT category, COUNT(*) … GROUP BY category (active rows only — the
// default scope). len(facts) is the distinct-category cardinality the
// insert rule caps. It runs under the request ctx when scoped, falling back to
// context.Background() only on the singleton (tests, background jobs).
//
// The port returns pure facts (no error) — the domain never handles IO. An
// unrecoverable query failure is INFRA's concern: it surfaces here as a panic
// that the pipeline's single recover point converts into a 500, so the write
// never happens (never a silent empty result that would skip the cap invariant).
func (s *ProductServiceImpl) ActiveCategoryFacts() []qadomain.ProductCategoryFact {
	var c context.Context = context.Background()
	if s.ctx != nil {
		c = s.ctx // *AppContext IS a context.Context — request deadline/trace reach the query
	}
	count := read.Count()
	groups, err := s.repo.Loader.AggregateBy(c, nil, read.By("Category"), count)
	if err != nil {
		panic("ProductServiceImpl.ActiveCategoryFacts: " + err.Error())
	}
	facts := make([]qadomain.ProductCategoryFact, 0, len(groups))
	for _, g := range groups {
		facts = append(facts, qadomain.ProductCategoryFact{
			Category: g.KeyString("Category"),
			Count:    read.GroupResult(g, count).Value,
		})
	}
	return facts
}

var _ qadomain.ProductService = (*ProductServiceImpl)(nil)
var _ persistence.ScopedServiceProvider = (*ProductServiceImpl)(nil)

// productScalarSpecs is the full spec vocabulary the stats read exercises,
// created fresh per call site (a spec instance is stateful).
type productScalarSpecs struct {
	count     *read.CountAgg
	sumCents  *read.IntAgg
	minCents  *read.IntAgg
	maxCents  *read.IntAgg
	avgWeight *read.FloatAgg
	sumWeight *read.FloatAgg
	minWeight *read.FloatAgg
	maxWeight *read.FloatAgg
}

func newProductScalarSpecs() productScalarSpecs {
	return productScalarSpecs{
		count:     read.Count(),
		sumCents:  read.SumInt("PriceCents"),
		minCents:  read.MinInt("PriceCents"),
		maxCents:  read.MaxInt("PriceCents"),
		avgWeight: read.Avg("Weight"),
		sumWeight: read.Sum("Weight"),
		minWeight: read.Min("Weight"),
		maxWeight: read.Max("Weight"),
	}
}

func (s productScalarSpecs) list() []read.AggregateSpec {
	return []read.AggregateSpec{
		s.count, s.sumCents, s.minCents, s.maxCents,
		s.avgWeight, s.sumWeight, s.minWeight, s.maxWeight,
	}
}

// stats reads the carriers into the application DTO. For the grouped path the
// carriers are the per-group clones resolved via GroupResult before calling.
func (s productScalarSpecs) stats() appqa.ProductScalarStats {
	return appqa.ProductScalarStats{
		Count:      s.count.Value,
		SumCents:   s.sumCents.Value,
		MinCents:   s.minCents.Value,
		MaxCents:   s.maxCents.Value,
		AvgWeight:  s.avgWeight.Value,
		SumWeight:  s.sumWeight.Value,
		MinWeight:  s.minWeight.Value,
		MaxWeight:  s.maxWeight.Value,
		FactsFound: s.sumCents.Found,
	}
}

// Stats answers the application port with exactly TWO SELECTs: the ungrouped
// facts (Aggregate) and the per-category facts (AggregateBy) — the whole spec
// vocabulary on each. It takes the request ctx explicitly (the read route passes
// it). includeArchived widens the scope the same way a read route's
// ?includeArchived does.
func (s *ProductServiceImpl) Stats(ctx *configuration.AppContext, includeArchived bool) (*appqa.ProductStatsResult, error) {
	q := criteria.Where(nil)
	if includeArchived {
		q = q.IncludeArchived()
	}

	global := newProductScalarSpecs()
	if err := s.repo.Loader.Aggregate(ctx, q, global.list()...); err != nil {
		return nil, err
	}

	perCat := newProductScalarSpecs()
	groups, err := s.repo.Loader.AggregateBy(ctx, q, read.By("Category"), perCat.list()...)
	if err != nil {
		return nil, err
	}
	cats := make([]appqa.ProductCategoryStats, 0, len(groups))
	for _, g := range groups {
		resolved := productScalarSpecs{
			count:     read.GroupResult(g, perCat.count),
			sumCents:  read.GroupResult(g, perCat.sumCents),
			minCents:  read.GroupResult(g, perCat.minCents),
			maxCents:  read.GroupResult(g, perCat.maxCents),
			avgWeight: read.GroupResult(g, perCat.avgWeight),
			sumWeight: read.GroupResult(g, perCat.sumWeight),
			minWeight: read.GroupResult(g, perCat.minWeight),
			maxWeight: read.GroupResult(g, perCat.maxWeight),
		}
		cats = append(cats, appqa.ProductCategoryStats{
			Category:           g.KeyString("Category"),
			ProductScalarStats: resolved.stats(),
		})
	}
	return &appqa.ProductStatsResult{Global: global.stats(), Categories: cats}, nil
}

var _ appqa.ProductStatsReader = (*ProductServiceImpl)(nil)
