//go:build !qa

package main

import (
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/web/authcore"
)

// qaFeatures is empty in the canonical (non-qa) build — no QA fixtures are
// compiled or wired into the binary.
func qaFeatures(_ bootstrap.Deps) []bootstrap.Feature { return nil }

// qaAuthWiring is a no-op in the canonical build — see wire_qa.go.
func qaAuthWiring(_ bootstrap.Deps) (bootstrap.Feature, authcore.RefreshTokenStore, authcore.TokenChecker) {
	return nil, nil, nil
}
