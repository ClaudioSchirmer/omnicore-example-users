//go:build qa

package qafixtures

import "github.com/ClaudioSchirmer/omnicore/domain"

// Product is a FLAT aggregate root whose whole reason to exist is the
// write-path aggregate DSL: its BuildRules consumes GROUPED scalar facts
// (per-category counts via the framework's AggregateBy) through a
// domain.Service port, and its /qa/products/stats endpoint serves the full
// spec vocabulary (Count/SumInt/Avg/MinInt/MaxInt + the float quartet) both
// ungrouped and grouped. PriceCents follows the framework's money doctrine
// (int64 minor units — exact arithmetic); Weight is the fractional
// counterpart for the float64 specs.
type Product struct {
	domain.AggregateRoot
	Code       string
	Category   string
	PriceCents int64
	Weight     float64
}

// Modes advertises the lifecycle verbs; Archive/Unarchive pair with the
// schema's SoftDelete so QA can prove the active-only scope gate rides the
// grouped SELECT (an archived product must fold out of its category group).
func (p *Product) Modes() []domain.EntityMode {
	return []domain.EntityMode{
		domain.ModeDisplay,
		domain.ModeInsert,
		domain.ModeUpdate,
		domain.ModeDelete,
		domain.ModeArchive,
		domain.ModeUnarchive,
	}
}

// RequiresService opts into mandatory Service injection: the insert rule
// below is meaningless without the stats port, so a nil Service must fail
// loudly (the framework emits ServiceIsRequiredNotification) instead of
// silently skipping the invariant.
func (p *Product) RequiresService() bool { return true }

// productCategoryLimit is the closed cap on DISTINCT active categories — the
// invariant that NEEDS grouped facts: a plain count answers "how many
// products", only a GROUP BY answers "how many categories".
const productCategoryLimit = 3

// BuildRules: Code + Category are required, PriceCents cannot be negative,
// and — the grouped-facts invariant — an insert may not create a fourth
// distinct category. Inserting into an EXISTING category is always fine; the
// cap gates only NEW keys, which is exactly the question len(groups) answers.
func (p *Product) BuildRules(_ string, svc domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if p.Code == "" {
			r.AddNotification("Code", domain.RequiredFieldNotification{})
		}
		if p.Category == "" {
			r.AddNotification("Category", domain.RequiredFieldNotification{})
		}
		if p.PriceCents < 0 {
			r.AddNotification("PriceCents", domain.SchemaViolationNotification{}, p.PriceCents)
		}
	})
	r.IfInsert(func() {
		if p.Category == "" {
			return // the required-field notification above already fired
		}
		ps, ok := svc.(*ProductService)
		if !ok || ps.Stats == nil {
			// RequiresService() true guards the nil-Service case before rules
			// run; a Service of the wrong TYPE is a wiring bug — fail loudly.
			panic("Product.BuildRules: the Service must be a *ProductService carrying the Stats port")
		}
		facts, err := ps.Stats.ActiveCategoryFacts()
		if err != nil {
			// A stats-backend failure is not a validation outcome: propagate as a
			// panic so the pipeline's single recover point converts it into the
			// 500 Exception envelope and the write never happens.
			panic("Product.BuildRules: category facts unavailable: " + err.Error())
		}
		for _, f := range facts {
			if f.Category == p.Category {
				return // existing category — the cap gates only new keys
			}
		}
		if len(facts) >= productCategoryLimit {
			r.AddNotification("Category", ProductCategoryLimitNotification{}, p.Category)
		}
	})
}
