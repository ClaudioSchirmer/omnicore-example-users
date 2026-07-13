//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/domain"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"

	"github.com/gofiber/fiber/v3"
)

// MountProducts registers the QA-only Product routes under /qa/products:
//
//	POST  /qa/products               Auto insert (ProductService injected —
//	                                 the grouped-facts rule fires in BuildRules)
//	PATCH /qa/products/:id/archive   soft-delete (folds the row out of the stats)
//	PATCH /qa/products/:id/unarchive restore
//	GET   /qa/products/stats         ungrouped + per-category scalar facts
//	                                 (Aggregate + AggregateBy, whole spec set)
//
// The fixture exists to exercise the write-path aggregate DSL end to end: the
// stats endpoint proves every spec (grouped and ungrouped) over both engines,
// and the insert rule proves BuildRules consuming grouped facts through a
// domain.Service.
func MountProducts(
	app *fiber.App,
	repo persistence.ScopedRepository[*qadomain.Product],
	service domain.Service,
	stats appqa.ProductStatsReader,
	d bootstrap.Deps,
) {
	g := app.Group("/qa/products")

	// Auto insert — Service injection is mandatory (Product.RequiresService()):
	// BuildRules asks the ProductService for the per-category facts and caps
	// the distinct-category cardinality.
	insertH, insertSpec := fwweb.CommandWithBodySpec(d.Pipeline,
		InsertProductRequest{},
		InsertProductResponse{}.FromResult,
		&handlers.InsertCommandHandler[*qadomain.Product, *appqa.InsertProductCommand, appqa.InsertProductResult]{
			Repo:    repo,
			Service: service,
		}, fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPost, "/",
		insertH, insertSpec,
		fwopenapi.Doc{
			Summary:     "Create a product (grouped-facts rule)",
			Description: "Creates a product via the Auto InsertCommandHandler with the ProductService injected. BuildRules consumes per-category counts computed by the framework's grouped aggregate DSL (AggregateBy) and rejects an insert that would create a fourth distinct active category (422 LimitExceededNotification). Inserting into an existing category always passes.",
			Tags:        []string{"QA Products"},
		},
		fwopenapi.RequirePermission("products:write"))

	// Archive / Unarchive — the soft-delete pair the stats suite uses to prove
	// the active-only scope gate rides the grouped SELECT.
	archiveH, archiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.ArchiveCommandHandler[*qadomain.Product, *appqa.ArchiveProductCommand, fwresults.None]{
			Repo:    repo,
			Service: service,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/archive",
		archiveH, archiveSpec,
		fwopenapi.Doc{
			Summary:     "Archive (soft-delete) a product",
			Description: "Soft-deletes the product: it folds out of the active stats (default scope) but stays visible under ?includeArchived=true.",
			Tags:        []string{"QA Products"},
		},
		fwopenapi.RequirePermission("products:archive"))

	unarchiveH, unarchiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.UnarchiveCommandHandler[*qadomain.Product, *appqa.UnarchiveProductCommand, fwresults.None]{
			Repo:    repo,
			Service: service,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/unarchive",
		unarchiveH, unarchiveSpec,
		fwopenapi.Doc{
			Summary:     "Unarchive a product",
			Description: "Restores a soft-deleted product — it folds back into the active stats.",
			Tags:        []string{"QA Products"},
		},
		fwopenapi.RequirePermission("products:archive"))

	// Stats — the aggregate-DSL read surface: ungrouped (Aggregate) + grouped
	// (AggregateBy), every spec on both. A raw route (not a view read): the
	// facts come from the RELATIONAL side through the write-path loader.
	fwopenapi.MountRaw(d.OpenAPIRegistry, g, fiber.MethodGet, "/stats",
		func(c fiber.Ctx) error {
			ctx := fwweb.AppContext(c)
			ctx.SetParent(c)
			includeArchived := c.Query("includeArchived") == "true"
			result, err := stats.Stats(ctx, includeArchived)
			if err != nil {
				return respondWithError(c, fiber.StatusInternalServerError, "product stats failed", err)
			}
			return fwweb.RespondWithSuccess(c, fiber.StatusOK, productStatsResponse(result))
		},
		fwopenapi.RawSpec{Summary: "Product scalar facts (Aggregate + AggregateBy)", Tags: []string{"QA Products"}, Hidden: true, Public: true})
}
