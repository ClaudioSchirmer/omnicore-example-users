//go:build !qa

package main

import (
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwgraphql "github.com/ClaudioSchirmer/omnicore/web/graphql"
	fwgrpc "github.com/ClaudioSchirmer/omnicore/web/grpc"
)

// qaFeatures is empty in the canonical (non-qa) build — no QA fixtures are
// compiled or wired into the binary.
func qaFeatures(_ bootstrap.Deps) []bootstrap.Feature { return nil }

// qaMountGraphQL is a no-op in the canonical build — no QA GraphQL fields.
func qaMountGraphQL(_ *fwgraphql.Registry, _ bootstrap.Deps) {}

// qaMountGRPC is a no-op in the canonical build — no QA gRPC fixtures.
func qaMountGRPC(_ *fwgrpc.Registry, _ bootstrap.Deps) {}
