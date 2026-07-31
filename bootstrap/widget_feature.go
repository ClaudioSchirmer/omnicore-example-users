//go:build qa

package main

import (
	"context"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"

	infraqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/infra/qafixtures"
	webqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/web/qafixtures"

	"github.com/gofiber/fiber/v3"
)

// WidgetFeature bundles the QA-only Widget aggregate (a normal aggregate with a
// native child array + two flat sibling facets) with its Mongo view AND the
// RelationalSource twin. It exists to prove the relational reader's
// root-own-column boundary end to end: the Mongo view row-selects on
// child/sibling fields, the relational twin returns 400. Present only in the `qa`
// build; always contributed (no CDC/upstream gating).
type WidgetFeature struct {
	repo    *infraqa.WidgetRepository
	view    *query.ViewDefinition
	relView *query.ViewDefinition
}

// NewWidgetFeature provisions the four Widget tables in the constructor (before
// the boot-time Mongo drift probe reads them), like the other QA features.
func NewWidgetFeature(d bootstrap.Deps) *WidgetFeature {
	if err := infraqa.ProvisionWidgetTables(context.Background(), d.DB); err != nil {
		panic("WidgetFeature: provisioning QA tables failed: " + err.Error())
	}
	// One loader per aggregate: the widget repository holds it (repo.Loader,
	// schema-bound), and the relational twin reuses THAT loader.
	repo := infraqa.NewWidgetRepository(d.DB)
	return &WidgetFeature{
		repo:    repo,
		view:    infraqa.WidgetView(),
		relView: infraqa.WidgetRelView(repo.Loader),
	}
}

// Views satisfies bootstrap.ReadableFeature: the Mongo projection (materialized
// by the SyncEngine on every widget change) plus the relational twin (skipped by
// the SyncEngine/Mongo spec passes — served straight from the SoR).
func (f *WidgetFeature) Views() []*query.ViewDefinition {
	return []*query.ViewDefinition{f.view, f.relView}
}

func (f *WidgetFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	webqa.MountWidgets(app, f.repo, f.view.Name(), d)
	webqa.MountWidgetsRel(app, f.relView, d)
}
