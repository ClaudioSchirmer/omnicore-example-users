//go:build qa

package main

import (
	"context"
	"os"

	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	"github.com/ClaudioSchirmer/omnicore/infra/integration"
	fwgraphql "github.com/ClaudioSchirmer/omnicore/web/graphql"
	fwgrpc "github.com/ClaudioSchirmer/omnicore/web/grpc"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
	infraqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/infra/qafixtures"
	webqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/web/qafixtures"

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
	// relView + cappedRelView are the RelationalSource read twins over the SAME
	// gadgets root (served from the SoR, no Mongo collection). Always contributed
	// in the qa build: a relational view carries no CDC/upstream dependency, so it
	// boots under every profile the qa binary runs.
	relView       *query.ViewDefinition
	cappedRelView *query.ViewDefinition
	// evolveView is the flippable mongo↔relational toggle view (gadgets_evolve),
	// contributed ONLY under QA_RELATIONAL_EVOLVE=1 (the relational_evolution
	// suite) so it stays invisible to every other suite.
	evolveView *query.ViewDefinition
	// embeddedView is nil unless the loaded config declares the
	// `upstream_gadgets` subscription (only microservice.qa.yaml does). It embeds
	// that upstream projection, and the §8.3 boot guard requires a matching
	// UpstreamSubscription — so contributing it under the prd configs the
	// auth/audit/authz suites boot (which carry no upstreamSubscriptions block)
	// would abort boot. Gated the same way MountReceivers gates `self_gadgets`.
	embeddedView *query.ViewDefinition
	// notesView is the GadgetNote's own projection — a regular view that also
	// serves as the 1:N leg of the composed read. Always contributed.
	notesView *query.ViewDefinition
	noteRepo  *infraqa.GadgetNoteRepository
	// fullView is the READ-TIME composition showcase (`gadgets_full`). Nil
	// unless the config declares the `upstream_gadgets` subscription: its 1:1
	// external leg must resolve to a locally materialized collection (R14), so
	// contributing it under the prd configs would abort boot — the same gating
	// embeddedView uses.
	fullView *query.ComposedViewDefinition
	// kitView is the EmbedInChild-over-upstream_gadgets showcase (qa_gadget_kits_view):
	// a native child array whose lines are enriched 1:1 from the upstream_gadgets
	// projection. Gated identically to embeddedView — its enrichment source is that
	// same projection, so it needs the upstream_gadgets subscription to boot.
	kitView   *query.ViewDefinition
	kitRepo   *infraqa.GadgetKitRepository
	journal   infraqa.GadgetJournalAdapter
	publisher infraqa.GadgetEventPublisherAdapter
	sink      *infraqa.GadgetEventSinkAdapter
	httpShow  *infraqa.QaHttpShowcase
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
	if err := infraqa.ProvisionGadgetNoteTable(context.Background(), d.DB); err != nil {
		panic("GadgetFeature: provisioning gadget_notes failed: " + err.Error())
	}
	if err := infraqa.ProvisionGadgetKitTables(context.Background(), d.DB); err != nil {
		panic("GadgetFeature: provisioning gadget_kits failed: " + err.Error())
	}
	// One loader per aggregate: the gadget repository already holds it
	// (repo.Loader, schema-bound). Both relational twins over the gadgets root
	// reuse THAT loader — no second AggregateLoader is constructed.
	repo := infraqa.NewGadgetRepository(d.DB)
	f := &GadgetFeature{
		repo:          repo,
		view:          infraqa.GadgetView(),
		hotView:       infraqa.GadgetHotView(),
		cappedView:    infraqa.GadgetCappedView(),
		relView:       infraqa.GadgetRelView(repo.Loader),
		cappedRelView: infraqa.GadgetCappedRelView(repo.Loader),
		notesView:     infraqa.GadgetNotesView(),
		noteRepo:      infraqa.NewGadgetNoteRepository(d.DB),
		journal:       infraqa.GadgetJournalAdapter{},
		publisher:     infraqa.GadgetEventPublisherAdapter{},
		sink:          infraqa.NewGadgetEventSinkAdapter(d.DB),
		httpShow:      infraqa.NewQaHttpShowcase(d.HttpClient),
	}
	// The flippable evolution view is opt-in: only the relational_evolution suite
	// (which sets QA_RELATIONAL_EVOLVE=1) contributes it, so no other suite pays
	// for an extra gadgets projection or a route it never exercises.
	if os.Getenv("QA_RELATIONAL_EVOLVE") == "1" {
		f.evolveView = infraqa.GadgetEvolveView(repo.Loader)
	}
	// The embedded view is only bootable when its embedded `upstream_gadgets`
	// projection has a declared subscription (microservice.qa.yaml). Under the
	// prd configs the other suites use, leave it nil so Views()/Mount skip it.
	// The composed view carries the same external leg, so it gates identically.
	if declaresUpstreamCollection(d, "upstream_gadgets") {
		f.embeddedView = infraqa.GadgetEmbeddedView()
		f.fullView = infraqa.GadgetFullView()
		f.kitView = infraqa.GadgetKitView()
		f.kitRepo = infraqa.NewGadgetKitRepository(d.DB)
	}
	return f
}

// declaresUpstreamCollection reports whether the loaded config declares an
// upstream subscription materializing the named Mongo collection. Used to gate
// the embedded view (and its route) so the qa binary stays bootable under the
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
	views := []*query.ViewDefinition{f.view, f.hotView, f.cappedView, f.notesView, f.relView, f.cappedRelView}
	if f.evolveView != nil {
		views = append(views, f.evolveView)
	}
	// gadgets_embedded embeds the upstream_gadgets projection; contributed only
	// when the config declares that subscription (see NewGadgetFeature).
	if f.embeddedView != nil {
		views = append(views, f.embeddedView)
	}
	if f.kitView != nil {
		views = append(views, f.kitView)
	}
	return views
}

// ComposedViews satisfies bootstrap.ComposingFeature: the read-time composed
// showcase (`gadgets_full`). Unlike Views(), nothing here reaches the
// SyncEngine — a composed view has no collection, no Version, no recompose;
// the framework only validates it and wires the composed decorator over the
// ViewReader. Nil (skipped) under configs without the upstream subscription.
func (f *GadgetFeature) ComposedViews() []*query.ComposedViewDefinition {
	if f.fullView == nil {
		return nil
	}
	return []*query.ComposedViewDefinition{f.fullView}
}

// Mount injects the journal + publisher ports for the Auto command hooks and
// registers the routes. Table provisioning happened in the constructor (see
// NewGadgetFeature) because Mount runs after the boot-time Mongo drift probe
// that reads them.
func (f *GadgetFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	appqa.UseJournal(f.journal)
	appqa.UsePublisher(f.publisher)
	webqa.MountGadgets(app, f.repo, f.journal, f.publisher, f.view, d)
	webqa.MountGadgetShowcase(app, f.hotView.Name(), f.cappedView.Name(), f.view.Name(), d)
	// Relational-source read twins (/qa/rel/gadgets*): parity + the 4xx and
	// MaxLimit/MaxExportRows surfaces the relational_view suite drives.
	webqa.MountGadgetsRel(app, f.relView, f.cappedRelView, d)
	if f.evolveView != nil {
		webqa.MountGadgetEvolve(app, f.evolveView.Name(), d)
	}
	// Embedded read surface (/qa/gadgets-embedded/:id) — mounted only when the
	// embedded view exists (i.e. the upstream_gadgets subscription is declared).
	if f.embeddedView != nil {
		webqa.MountGadgetEmbedded(app, f.embeddedView.Name(), d)
	}
	// EmbedInChild showcase (/qa/gadget-kits/*) — gated with the kit view.
	if f.kitView != nil {
		webqa.MountGadgetKits(app, f.kitRepo, f.kitView.Name(), f.kitView, d)
	}
	// GadgetNote surface (create/archive + the leg view's own list) — always.
	webqa.MountGadgetNotes(app, f.noteRepo, f.notesView.Name(), d)
	// Composed read surface (/qa/gadgets-full/*) — gated with the composed view.
	if f.fullView != nil {
		webqa.MountGadgetsFull(app, f.fullView, d)
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

// MountGraphQL satisfies bootstrap.GraphQLFeature: it contributes the QA-only
// `gadgetsFull` connection over the COMPOSED gadgets_full view into the shared
// GraphQL registry, resolving through the same ViewReader port the canonical
// fields use (so the read-time composition arrives with zero GraphQL-specific
// wiring). Gated on the `upstream_gadgets` subscription (only microservice.qa.yaml
// declares it), exactly like embeddedView — under the prd configs the leg is
// absent so the field stays unmounted and the surface still boots.
func (f *GadgetFeature) MountGraphQL(reg *fwgraphql.Registry, d bootstrap.Deps) {
	// `gadgetsRel` is the RelationalSource twin on the GraphQL surface — the SAME
	// DTO seats and query handler as the REST mirror, only the View name differs.
	// It exists so the Relay connection envelope (edges/pageInfo/totalCount) is
	// proven over a relationally served view and not only over a Mongo one: the
	// two readers reach the surface through the same queries.Page, and totalCount
	// reads Page.Total. Registered BEFORE the upstream gate below — a relational
	// view carries no CDC/upstream dependency, so it mounts under every profile.
	reg.Register(fwgraphql.QueryWithParams[webqa.FindGadgetsRequest](
		"gadgetsRel", "GadgetRel",
		webqa.FindGadgetsResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery, appqa.FindGadgetsResult]{
			Reader: d.ViewReader, View: f.relView.Name(),
		},
		fwgraphql.RequirePermission("gadgets:read")))

	// `gadgetsBare` is the reserved-gate proof on the GraphQL surface: its
	// Request DTO declares NO reserved control keys, so the SDL cut removes
	// every connection argument except `where` — introspection and the
	// playground never advertise them, and gqlparser rejects them as unknown
	// arguments before any resolver runs. The natural selections (projection,
	// only-total shape) stay valid — they are the language, not arguments.
	reg.Register(fwgraphql.QueryWithParams[webqa.FindGadgetsBareRequest](
		"gadgetsBare", "GadgetBare",
		webqa.FindGadgetsResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery, appqa.FindGadgetsResult]{
			Reader: d.ViewReader, View: f.view.Name(),
		},
		fwgraphql.RequirePermission("gadgets:read")))

	if !declaresUpstreamCollection(d, "upstream_gadgets") {
		return
	}
	reg.Register(fwgraphql.QueryWithParams[webqa.FindGadgetsFullRequest](
		"gadgetsFull", "GadgetFull",
		webqa.FindGadgetsFullResponse{}.FromResult,
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsFullQuery, appqa.FindGadgetsFullResult]{
			Reader: d.ViewReader, View: "gadgets_full",
		},
		fwgraphql.RequirePermission("gadgets:read")))
}

// MountGRPC satisfies bootstrap.GRPCFeature: it contributes the QA-only gRPC
// fixture surface (Provoke's full Semantic table, the gadgets StringOp
// vocabulary, the FlakyEcho/Boom transport fixtures) into the shared gRPC
// registry — the discovered twin of the canonical UsersService MountGRPC.
func (f *GadgetFeature) MountGRPC(reg *fwgrpc.Registry, d bootstrap.Deps) {
	webqa.MountQAGRPC(reg, d)
}
