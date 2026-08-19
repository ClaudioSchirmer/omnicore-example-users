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

// TenantFeature bundles the QA-only Tenant aggregate with its Mongo view. It
// backs the `old_state_archive` suite: birth-time domain.Old, CompleteAsArchive,
// domain/command mutations persisted by archive and unarchive, and the child
// cascade around all of it. Present only in the `qa` build.
type TenantFeature struct {
	repo *infraqa.TenantRepository
	view *query.ViewDefinition
}

// NewTenantFeature provisions the two Tenant tables in the constructor (before
// the boot-time Mongo drift probe reads them), like the other QA features.
func NewTenantFeature(d bootstrap.Deps) *TenantFeature {
	if err := infraqa.ProvisionTenantTables(context.Background(), d.DB); err != nil {
		panic("TenantFeature: provisioning QA tables failed: " + err.Error())
	}
	return &TenantFeature{
		repo: infraqa.NewTenantRepository(d.DB),
		view: infraqa.TenantView(),
	}
}

func (f *TenantFeature) Views() []*query.ViewDefinition {
	return []*query.ViewDefinition{f.view}
}

func (f *TenantFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	webqa.MountTenants(app, f.repo, f.view.Name(), d)
}
