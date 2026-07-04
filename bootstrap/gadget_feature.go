//go:build qa

package main

import (
	"context"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	"github.com/ClaudioSchirmer/omnicore/infra/integration"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/application/qafixtures"
	infraqa "github.com/ClaudioSchirmer/omnicore-example-users/infra/qafixtures"
	webqa "github.com/ClaudioSchirmer/omnicore-example-users/web/qafixtures"

	"github.com/gofiber/fiber/v3"
)

// GadgetFeature bundles the QA-only Gadget aggregate's repo + view + journal
// adapter + integration producer/consumer adapters and mounts the
// /qa/gadgets/* routes. Implements bootstrap.ReadableFeature so the gadgets view
// is contributed to the SyncEngine (CDC materializes the gadgets Mongo
// collection) and bootstrap.IntegrationFeature so it registers the self-consumed
// `gadgetCreated` receiver. Present only in the `qa` build.
type GadgetFeature struct {
	repo       *infraqa.GadgetRepository
	view       *query.ViewDefinition
	hotView    *query.ViewDefinition
	cappedView *query.ViewDefinition
	// composedView is nil unless the loaded config declares the
	// `upstream_gadgets` subscription (only microservice.qa.yaml does). It embeds
	// that upstream projection, and the §8.3 boot guard requires a matching
	// UpstreamSubscription — so contributing it under the prd configs the
	// auth/audit/authz suites boot (which carry no upstreamSubscriptions block)
	// would abort boot. Gated the same way MountReceivers gates `self_gadgets`.
	composedView *query.ViewDefinition
	journal      infraqa.GadgetJournalAdapter
	publisher    infraqa.GadgetEventPublisherAdapter
	sink         *infraqa.GadgetEventSinkAdapter
	httpShow     *infraqa.QaHttpShowcase
}

// NewGadgetFeature is constructed inside Wire(deps), which bootstrap.Run calls
// AFTER the relational engine connects but BEFORE it applies migrations and
// reconciles the Mongo views. That ordering is why the QA tables are
// provisioned HERE (constructor) rather than in Mount: the gadgets root table
// must exist before the framework's boot-time Mongo drift probe reads it, and
// Mount runs after that probe. Idempotent CREATE IF NOT EXISTS; a failure is a
// boot-fatal misconfiguration, so it panics like the rest of the boot path.
func NewGadgetFeature(d bootstrap.Deps) *GadgetFeature {
	if err := infraqa.ProvisionGadgetTables(context.Background(), d.DB); err != nil {
		panic("GadgetFeature: provisioning QA tables failed: " + err.Error())
	}
	f := &GadgetFeature{
		repo:       infraqa.NewGadgetRepository(d.DB),
		view:       infraqa.GadgetView(),
		hotView:    infraqa.GadgetHotView(),
		cappedView: infraqa.GadgetCappedView(),
		journal:    infraqa.GadgetJournalAdapter{},
		publisher:  infraqa.GadgetEventPublisherAdapter{},
		sink:       infraqa.NewGadgetEventSinkAdapter(d.DB),
		httpShow:   infraqa.NewQaHttpShowcase(d.HttpClient),
	}
	// The composed view is only bootable when its embedded `upstream_gadgets`
	// projection has a declared subscription (microservice.qa.yaml). Under the
	// prd configs the other suites use, leave it nil so Views()/Mount skip it.
	if declaresUpstreamCollection(d, "upstream_gadgets") {
		f.composedView = infraqa.GadgetComposedView()
	}
	return f
}

// declaresUpstreamCollection reports whether the loaded config declares an
// upstream subscription materializing the named Mongo collection. Used to gate
// the composed view (and its route) so the qa binary stays bootable under the
// prd profiles that carry no upstreamSubscriptions block.
func declaresUpstreamCollection(d bootstrap.Deps, collection string) bool {
	if d.Config == nil {
		return false
	}
	for _, s := range d.Config.UpstreamSubscriptions {
		if s.Collection == collection {
			return true
		}
	}
	return false
}

// Views satisfies bootstrap.ReadableFeature. Besides the default `gadgets`
// projection it contributes the two read-side-option showcase views over the
// SAME gadgets root: `gadgets_hot` (DeleteOnArchive) and `gadgets_capped`
// (MaxLimit 5). All three are materialized by the SyncEngine on every gadgets
// change.
func (f *GadgetFeature) Views() []*query.ViewDefinition {
	views := []*query.ViewDefinition{f.view, f.hotView, f.cappedView}
	// gadgets_composed embeds the upstream_gadgets projection; contributed only
	// when the config declares that subscription (see NewGadgetFeature).
	if f.composedView != nil {
		views = append(views, f.composedView)
	}
	return views
}

// Mount injects the journal + publisher ports for the Auto command hooks and
// registers the routes. Table provisioning happened in the constructor (see
// NewGadgetFeature) because Mount runs after the boot-time Mongo drift probe
// that reads them.
func (f *GadgetFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	appqa.UseJournal(f.journal)
	appqa.UsePublisher(f.publisher)
	webqa.MountGadgets(app, f.repo, f.journal, f.publisher, f.view.Name(), d)
	webqa.MountGadgetShowcase(app, f.hotView.Name(), f.cappedView.Name(), f.view.Name(), d)
	// Composed read surface (/qa/gadgets-composed/:id) — mounted only when the
	// composed view exists (i.e. the upstream_gadgets subscription is declared).
	if f.composedView != nil {
		webqa.MountGadgetComposed(app, f.composedView.Name(), d)
	}
	// Outbound httpclient-advanced showcase: the /qa/echo/* upstream + the
	// /qa/showcase/httpclient/* consumer routes driving the QaHttpShowcase
	// adapter (retry, breaker, idempotency, xml, static auth + WithExtraHeader).
	webqa.MountQaEcho(app, d)
	webqa.MountQaHttpShowcase(app, f.httpShow, d)
}

// MountReceivers satisfies bootstrap.IntegrationFeature: it registers the
// self-consumed `gadgetCreated` receiver on the `self_gadgets` source. Each
// consumed message is unmarshalled into GadgetCreatedReceivedRequest, mapped via
// ToCommand to a RecordGadgetEventCommand, and handled by RecordGadgetEventHandler,
// which writes one idempotent row to gadget_events_sink. The registry
// eager-validates the sample/handler shapes here at boot.
func (f *GadgetFeature) MountReceivers(reg *integration.Registry, d bootstrap.Deps) {
	// Only register the self-consumed receiver when the loaded config actually
	// declares the `self_gadgets` subscribe source. This keeps the qa binary
	// universally bootable: the auth/audit/authz suites run it under prd configs
	// that carry no integration.subscribes block, and the registry eager-validates
	// every registered receiver against YAML — an unconditional registration would
	// panic wherever the subscribe coordinate is absent. When the subscribe is
	// present (microservice.qa.yaml) the receiver is wired exactly as before.
	if d.Config == nil || d.Config.Integration == nil {
		return
	}
	if _, _, ok := d.Config.Integration.LookupSubscribe("self_gadgets", "gadgetCreated"); !ok {
		return
	}
	reg.From("self_gadgets").On(
		"gadgetCreated",
		webqa.GadgetCreatedReceivedRequest{},
		&appqa.RecordGadgetEventHandler{Sink: f.sink},
	)
}
