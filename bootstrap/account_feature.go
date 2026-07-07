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

// AccountFeature bundles the QA-only EXTERNAL-EMBED showcase — the fixture that
// proves the full matrix {normal view, shared-base view} × {Embed 1:1,
// EmbedMany 1:N}, which no other fixture exercises:
//
//   - Item (flat aggregate) → the `upstream_items` projection (the external
//     embed source shared by both views).
//   - AccountHolder (shared-base role) → `qa_accounts_view` (SharedBaseView)
//     embedding upstream_items 1:1 (featuredItem) AND 1:N (items, via account_id).
//   - Catalog (normal aggregate) → `qa_catalog_view` (query.View) embedding the
//     SAME upstream_items 1:1 (featuredItem) AND 1:N (items, via catalog_id).
//
// The views (and the whole route surface) are contributed ONLY when the loaded
// config declares the `upstream_items` subscription (microservice.qa.yaml):
// their embeds require that locally materialized collection, so contributing
// them under the prd configs the auth/audit/authz suites use — which carry no
// upstreamSubscriptions block — would abort boot. Gated exactly like the Gadget
// embeddedView.
type AccountFeature struct {
	accountRepo *infraqa.AccountHolderRepository
	catalogRepo *infraqa.CatalogRepository
	itemRepo    *infraqa.ItemRepository
	accountView *query.ViewDefinition
	catalogView *query.ViewDefinition
}

// NewAccountFeature provisions the QA tables in the constructor (before the
// boot-time Mongo drift probe reads them, same reason as GadgetFeature) and
// contributes the views only when their upstream projection is declared.
func NewAccountFeature(d bootstrap.Deps) *AccountFeature {
	if err := infraqa.ProvisionAccountTables(context.Background(), d.DB); err != nil {
		panic("AccountFeature: provisioning qa_accounts/qa_account_holders failed: " + err.Error())
	}
	if err := infraqa.ProvisionCatalogTable(context.Background(), d.DB); err != nil {
		panic("AccountFeature: provisioning qa_catalogs failed: " + err.Error())
	}
	if err := infraqa.ProvisionItemTable(context.Background(), d.DB); err != nil {
		panic("AccountFeature: provisioning qa_items failed: " + err.Error())
	}
	f := &AccountFeature{
		accountRepo: infraqa.NewAccountHolderRepository(d.DB),
		catalogRepo: infraqa.NewCatalogRepository(d.DB),
		itemRepo:    infraqa.NewItemRepository(d.DB),
	}
	if declaresUpstreamCollection(d, "upstream_items") {
		f.accountView = infraqa.AccountView()
		f.catalogView = infraqa.CatalogView()
	}
	return f
}

// Views satisfies bootstrap.ReadableFeature: both embed views are materialized
// by the SyncEngine and their embeds registered for recompose-ripple. Nil under
// configs without the upstream_items subscription (see NewAccountFeature).
func (f *AccountFeature) Views() []*query.ViewDefinition {
	if f.accountView == nil {
		return nil
	}
	return []*query.ViewDefinition{f.accountView, f.catalogView}
}

// Mount registers the /qa/items + /qa/accounts + /qa/catalogs routes — only when
// the views are contributed, so the qa binary stays bootable under prd profiles.
func (f *AccountFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	if f.accountView == nil {
		return
	}
	webqa.MountItems(app, f.itemRepo, d)
	webqa.MountAccounts(app, f.accountRepo, f.accountView, d)
	webqa.MountCatalogs(app, f.catalogRepo, f.catalogView, d)
}
