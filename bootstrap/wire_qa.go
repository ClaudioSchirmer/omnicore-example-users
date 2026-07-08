//go:build qa

package main

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwgraphql "github.com/ClaudioSchirmer/omnicore/web/graphql"
	fwgrpc "github.com/ClaudioSchirmer/omnicore/web/grpc"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
	webqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/web/qafixtures"
)

// qaFeatures returns the QA-only features appended to the canonical set when
// the binary is built with the `qa` build tag. This is the only difference in
// the wired feature list between the canonical and the QA builds.
func qaFeatures(d bootstrap.Deps) []bootstrap.Feature {
	return []bootstrap.Feature{
		NewShowcaseFeature(d),
		NewAdminFeature(),
		NewGadgetFeature(d),
		NewAccountFeature(d),
	}
}

// qaMountGRPC contributes the QA-only gRPC fixture surface (Provoke's full
// Semantic table, the gadgets StringOp vocabulary, the FlakyEcho/Boom
// transport fixtures) — the gRPC twin of qaMountGraphQL.
func qaMountGRPC(reg *fwgrpc.Registry, d bootstrap.Deps) {
	webqa.MountQAGRPC(reg, d)
}

// qaMountGraphQL contributes the QA-only GraphQL fields when the qa binary
// runs under a config that can boot them. The `gadgetsFull` connection reads
// the COMPOSED view through the exact same registry/handler shape the
// canonical fields use — GraphQL resolves through the ViewReader port, so the
// read-time composition (segments, LEFT semantics, segment filters) arrives
// with zero GraphQL-specific wiring. Gated like the composed view itself: its
// external leg needs the `upstream_gadgets` subscription (microservice.qa.yaml).
func qaMountGraphQL(gql *fwgraphql.Registry, d bootstrap.Deps) {
	if !declaresUpstreamCollection(d, "upstream_gadgets") {
		return
	}
	gql.Register(fwgraphql.QueryWithParams[
		webqa.FindGadgetsFullRequest,
		webqa.FindGadgetsFullResponse,
	](
		"gadgetsFull", "GadgetFull",
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsFullQuery]{
			Reader: d.ViewReader, View: "gadgets_full",
		},
		fwgraphql.RequirePermission("gadgets:read")))
}
