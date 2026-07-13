//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/domain"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
)

// ─── Insert ──────────────────────────────────────────────────────────────────

// InsertProductRequest is the JSON body of POST /qa/products. PriceCents is
// the money shape (int64 minor units); Weight the fractional counterpart.
type InsertProductRequest struct {
	Code       string  `json:"code"       example:"PRD-001"`
	Category   string  `json:"category"   example:"books"`
	PriceCents int64   `json:"priceCents" example:"1050"`
	Weight     float64 `json:"weight"     example:"1.5"`
}

func (r InsertProductRequest) ToCommand() *appqa.InsertProductCommand {
	return &appqa.InsertProductCommand{
		Code:       r.Code,
		Category:   r.Category,
		PriceCents: r.PriceCents,
		Weight:     r.Weight,
	}
}

// InsertProductResponse is the wire shape of a successful insert.
type InsertProductResponse struct {
	ID         domain.ID `json:"id"         example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	Code       string    `json:"code"       example:"PRD-001"`
	Category   string    `json:"category"   example:"books"`
	PriceCents int64     `json:"priceCents" example:"1050"`
	Weight     float64   `json:"weight"     example:"1.5"`
}

func (InsertProductResponse) FromResult(r appqa.InsertProductResult) InsertProductResponse {
	return InsertProductResponse{
		ID:         r.ID,
		Code:       r.Code,
		Category:   r.Category,
		PriceCents: r.PriceCents,
		Weight:     r.Weight,
	}
}

// ─── Stats ───────────────────────────────────────────────────────────────────

// ProductScalarStatsOutput is the wire shape of one row of scalar facts —
// the whole aggregate-spec vocabulary over PriceCents (exact) and Weight
// (fractional). found mirrors the DSL's Found flag (false ⇔ nothing matched).
type ProductScalarStatsOutput struct {
	Count     int64   `json:"count"     example:"3"`
	SumCents  int64   `json:"sumCents"  example:"1670"`
	MinCents  int64   `json:"minCents"  example:"120"`
	MaxCents  int64   `json:"maxCents"  example:"1050"`
	AvgWeight float64 `json:"avgWeight" example:"2.25"`
	SumWeight float64 `json:"sumWeight" example:"6.75"`
	MinWeight float64 `json:"minWeight" example:"1.5"`
	MaxWeight float64 `json:"maxWeight" example:"3.0"`
	Found     bool    `json:"found"     example:"true"`
}

// ProductCategoryStatsOutput is ProductScalarStatsOutput keyed by its
// GROUP BY category.
type ProductCategoryStatsOutput struct {
	Category string `json:"category" example:"books"`
	ProductScalarStatsOutput
}

// ProductStatsResponse is the wire shape of GET /qa/products/stats: the
// ungrouped facts plus one entry per category, ordered by category ascending
// (the deterministic order AggregateBy guarantees).
type ProductStatsResponse struct {
	Global     ProductScalarStatsOutput     `json:"global"`
	Categories []ProductCategoryStatsOutput `json:"categories"`
}

func productScalarStatsOutput(s appqa.ProductScalarStats) ProductScalarStatsOutput {
	return ProductScalarStatsOutput{
		Count:     s.Count,
		SumCents:  s.SumCents,
		MinCents:  s.MinCents,
		MaxCents:  s.MaxCents,
		AvgWeight: s.AvgWeight,
		SumWeight: s.SumWeight,
		MinWeight: s.MinWeight,
		MaxWeight: s.MaxWeight,
		Found:     s.FactsFound,
	}
}

func productStatsResponse(r *appqa.ProductStatsResult) ProductStatsResponse {
	cats := make([]ProductCategoryStatsOutput, 0, len(r.Categories))
	for _, c := range r.Categories {
		cats = append(cats, ProductCategoryStatsOutput{
			Category:                 c.Category,
			ProductScalarStatsOutput: productScalarStatsOutput(c.ProductScalarStats),
		})
	}
	return ProductStatsResponse{
		Global:     productScalarStatsOutput(r.Global),
		Categories: cats,
	}
}
