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

// LensFeature contributes the MATERIALIZED view-on-view chain — the
// query.JoinView embed showcase — as a SIDE family that leaves every existing
// fixture untouched:
//
//	qa_lens_brands_view ─┐
//	                     ├─1:1 Embed→ qa_lens_parts_view ─1:N EmbedMany→ qa_lens_kits_view
//	gadgets (existing) ──┘
//
// Note what it does NOT need, and that absence is the point: no
// UpstreamSubscription, no broker topic, no consumer group, no mirror
// collection. The `gadgets` view it embeds is the one the service already
// projects; the framework signals every write to it and ripples the two hops
// in-process. That is why this feature is contributed UNCONDITIONALLY (unlike
// the upstream-mirror showcases, which are gated on their subscription being
// declared): it boots under every profile the QA suites use.
type LensFeature struct {
	brandRepo    *infraqa.LensBrandRepository
	kitRepo      *infraqa.LensKitRepository
	partRepo     *infraqa.LensPartRepository
	brandsView    *query.ViewDefinition
	brandsRelView *query.ViewDefinition
	kitsView      *query.ViewDefinition
	kitsDescView  *query.ViewDefinition
	partsView     *query.ViewDefinition
}

// NewLensFeature provisions the two QA tables in the constructor for the same
// reason GadgetFeature does: they must exist before the boot-time Mongo drift
// probe reads them, and Mount runs after that probe.
func NewLensFeature(d bootstrap.Deps) *LensFeature {
	if err := infraqa.ProvisionLensTables(context.Background(), d.DB); err != nil {
		panic("LensFeature: provisioning QA tables failed: " + err.Error())
	}
	// The brand repository's loader (schema-bound) is threaded into the relational
	// twin — one loader, shared with the repo, not a second construction.
	brandRepo := infraqa.NewLensBrandRepository(d.DB)
	return &LensFeature{
		brandRepo:     brandRepo,
		kitRepo:       infraqa.NewLensKitRepository(d.DB),
		partRepo:      infraqa.NewLensPartRepository(d.DB),
		brandsView:    infraqa.LensBrandsView(),
		brandsRelView: infraqa.LensBrandsRelView(brandRepo.Loader),
		kitsView:      infraqa.LensKitsView(),
		kitsDescView:  infraqa.LensKitsDescView(),
		partsView:     infraqa.LensPartsView(),
	}
}

// Views satisfies bootstrap.ReadableFeature. Both hops are ordinary
// materialized views — the SyncEngine projects each one from its own root
// table, and the embed signal keeps the segments fresh across the chain.
func (f *LensFeature) Views() []*query.ViewDefinition {
	return []*query.ViewDefinition{f.brandsView, f.brandsRelView, f.partsView, f.kitsView, f.kitsDescView}
}

func (f *LensFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	webqa.MountLensBrands(app, f.brandRepo, f.brandsView.Name(), d)
	webqa.MountLensBrandsRel(app, f.brandsRelView, d)
	webqa.MountLensParts(app, f.partRepo, f.partsView.Name(), d)
	webqa.MountLensKits(app, f.kitRepo, f.kitsView.Name(), d)
	webqa.MountLensKitsDesc(app, f.kitsDescView.Name(), d)
}
