//go:build !qa

package main

import "github.com/ClaudioSchirmer/omnicore/bootstrap"

// qaFeatures is empty in the canonical (non-qa) build — no QA fixtures are
// compiled or wired into the binary.
func qaFeatures(_ bootstrap.Deps) []bootstrap.Feature { return nil }
