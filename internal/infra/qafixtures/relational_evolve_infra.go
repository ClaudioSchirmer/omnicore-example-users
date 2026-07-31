//go:build qa

// This file declares the TOGGLE view the `relational_evolution` suite flips
// between its Mongo and RelationalSource variants (patch-rebuild-reboot) to prove
// the mongo↔relational drift transitions end to end on a SINGLE view name over the
// shared gadgets root. It is contributed ONLY when QA_RELATIONAL_EVOLVE=1 (the
// suite sets it), so it is invisible to every other QA suite. Present only in the
// `qa` build.
package qafixtures

import "github.com/ClaudioSchirmer/omnicore/infra/db/query"

// GadgetEvolveView is the flippable view `gadgets_evolve` over the SAME gadgets
// root, served through the gadget repository's loader (reused, not rebuilt).
//
// The suite rewrites the single marker line below to switch backings:
//
//	Mongo variant       (default):  _ = loader                       // RELATIONAL_EVOLVE_MARKER
//	Relational variant  (patched):  v = v.RelationalSource(loader)    // RELATIONAL_EVOLVE_MARKER
//
// so a rebuild of the qa binary produces either a Mongo-projected or a
// SoR-served `gadgets_evolve`, and the drift engine decides the transition at the
// next boot (DriftRelationalSync one way, a rebuild the other).
func GadgetEvolveView(loader query.RelationalReader) *query.ViewDefinition {
	v := query.View("gadgets_evolve").
		Version(1).
		Schema(GadgetSchema())
	_ = loader // RELATIONAL_EVOLVE_MARKER
	return v
}
