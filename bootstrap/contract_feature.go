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

// ContractFeature contributes the COMPOSITE VALUE OBJECT family: one flat
// aggregate whose five persisted columns come from two value objects plus one
// scalar one. It declares BOTH read backings over the same root — the Mongo
// projection and the RelationalSource twin — because decomposition has to hold
// on each, and they reach the document by different code paths.
type ContractFeature struct {
	repo    *infraqa.ContractRepository
	view    *query.ViewDefinition
	relView *query.ViewDefinition
}

// NewContractFeature provisions the QA table in the constructor for the same
// reason the other fixtures do: it must exist before the boot-time Mongo drift
// probe reads it, and Mount runs after that probe.
func NewContractFeature(d bootstrap.Deps) *ContractFeature {
	if err := infraqa.ProvisionContractTables(context.Background(), d.DB); err != nil {
		panic("ContractFeature: provisioning QA tables failed: " + err.Error())
	}
	repo := infraqa.NewContractRepository(d.DB)
	return &ContractFeature{
		repo:    repo,
		view:    infraqa.ContractsView(),
		relView: infraqa.ContractsRelView(repo.Loader),
	}
}

func (f *ContractFeature) Views() []*query.ViewDefinition {
	return []*query.ViewDefinition{f.view, f.relView}
}

func (f *ContractFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	webqa.MountContracts(app, f.repo, f.view.Name(), d)
	webqa.MountContractsRel(app, f.relView.Name(), d)
}
