//go:build qa

package main

import (
	"context"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"

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
	service *infraqa.ProductServiceImpl
}

// NewProductFeature provisions the qa_products table in the constructor for
// the same reason GadgetFeature does: idempotent CREATE IF NOT EXISTS before
// anything reads it; a failure is a boot-fatal misconfiguration.
func NewProductFeature(d bootstrap.Deps) *ProductFeature {
	if err := infraqa.ProvisionProductTable(context.Background(), d.DB); err != nil {
		panic("ProductFeature: provisioning qa_products failed: " + err.Error())
	}
	repo := infraqa.NewProductRepository(d.DB)
	return &ProductFeature{
		repo:    repo,
		service: infraqa.NewProductService(repo),
	}
}

// Mount registers the routes. ProductServiceImpl is BOTH the domain.Service the
// insert rule requires (ProductService) and the /stats read port — the Auto
// handler scopes it to the request ctx via persistence.ScopeService, so
// ActiveCategoryFacts runs under the request deadline/trace.
func (f *ProductFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	webqa.MountProducts(app, f.repo, f.service, f.service, d)
}
