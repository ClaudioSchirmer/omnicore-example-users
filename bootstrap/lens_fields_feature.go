//go:build qa

package main

import (
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"

	infraqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/infra/qafixtures"
	webqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/web/qafixtures"

	"github.com/gofiber/fiber/v3"
)

// LensFieldsFeature contributes the JoinView FIELDS family — three additional
// projections over the EXISTING lens roots, each with a Fields allowlist on its
// leg (see internal/infra/qafixtures/lens_fields_infra.go). Deliberately a
// SEPARATE feature from LensFeature: it adds views and read routes only, no
// repositories and no tables of its own (LensFeature provisions the roots and
// owns every write verb), so the original family is untouched.
type LensFieldsFeature struct {
	foreverView   *query.ViewDefinition
	lifecycleView *query.ViewDefinition
	kitsView      *query.ViewDefinition
}

func NewLensFieldsFeature() *LensFieldsFeature {
	return &LensFieldsFeature{
		foreverView:   infraqa.LensFieldsForeverView(),
		lifecycleView: infraqa.LensFieldsLifecycleView(),
		kitsView:      infraqa.LensFieldsKitsView(),
	}
}

// Views satisfies bootstrap.ReadableFeature — three more projections over the
// same event streams the lens family already produces.
func (f *LensFieldsFeature) Views() []*query.ViewDefinition {
	return []*query.ViewDefinition{f.foreverView, f.lifecycleView, f.kitsView}
}

func (f *LensFieldsFeature) Mount(app *fiber.App, d bootstrap.Deps) {
	webqa.MountLensFields(app, f.foreverView.Name(), f.lifecycleView.Name(), f.kitsView.Name(), d)
}
