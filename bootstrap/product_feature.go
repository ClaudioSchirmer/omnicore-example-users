//go:build qa

package main

import (
	"context"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
	infraqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/infra/qafixtures"
	webqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/web/qafixtures"

	"github.com/gofiber/fiber/v3"
)

// ProductFeature bundles the QA-only Product aggregate: repo + the stats
// adapter (the aggregate-DSL consumer, grouped AND ungrouped) + the
// ProductService the insert rule requires, and mounts the /qa/products/*
// routes. No Mongo view and no CDC — the whole fixture lives on the
// relational write path, which is exactly the surface the aggregate DSL
// serves. Present only in the `qa` build.
type ProductFeature struct {
	repo    *infraqa.ProductRepository
	stats   *infraqa.ProductStatsAdapter
	service *qadomain.ProductService
}

// NewProductFeature provisions the qa_products table in the constructor for
// the same reason GadgetFeature does: idempotent CREATE IF NOT EXISTS before
// anything reads it; a failure is a boot-fatal misconfiguration.
func NewProductFeature(d bootstrap.Deps) *ProductFeature {
	if err := infraqa.ProvisionProductTable(context.Background(), d.DB); err != nil {
		panic("ProductFeature: provisioning qa_products failed: " + err.Error())
	}
	repo := infraqa.NewProductRepository(d.DB)
	stats := infraqa.NewProductStatsAdapter(repo)
	return &ProductFeature{
		repo:    repo,
		stats:   stats,
		service: &qadomain.ProductService{Stats: stats},
	}
}

// Mount registers the routes with the service + stats reader wired in.
func (f *ProductFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	webqa.MountProducts(app, f.repo, f.service, f.stats, d)
}
