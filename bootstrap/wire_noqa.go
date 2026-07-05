//go:build !qa

package main

import (
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwgraphql "github.com/ClaudioSchirmer/omnicore/web/graphql"
)

// qaFeatures is empty in the canonical (non-qa) build — no QA fixtures are
// compiled or wired into the binary.
func qaFeatures(_ bootstrap.Deps) []bootstrap.Feature { return nil }

// qaMountGraphQL is a no-op in the canonical build — no QA GraphQL fields.
func qaMountGraphQL(_ *fwgraphql.Registry, _ bootstrap.Deps) {}
