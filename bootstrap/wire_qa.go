//go:build qa

package main

import "github.com/ClaudioSchirmer/omnicore/bootstrap"

// qaFeatures returns the QA-only features appended to the canonical set when
// the binary is built with the `qa` build tag. This is the only difference in
// the wired feature list between the canonical and the QA builds.
func qaFeatures(d bootstrap.Deps) []bootstrap.Feature {
	return []bootstrap.Feature{
		NewShowcaseFeature(d),
		NewAdminFeature(),
		NewGadgetFeature(d),
	}
}
