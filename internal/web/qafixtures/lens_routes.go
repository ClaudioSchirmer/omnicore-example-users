//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"

	"github.com/gofiber/fiber/v3"
)

// MountLensKitsDesc exposes the descending-order twin of the kits view — a
// read-only surface over a SECOND projection of the same root, so the suite can
// observe .Desc() beside the ascending one.
func MountLensKitsDesc(app *fiber.App, viewName string, d bootstrap.Deps) {
	g := app.Group("/qa/lens-kits-desc")
	byIDH, byIDSpec := fwweb.QueryByIDSpec(d.Pipeline,
		FindLensKitByIDRequest{},
		fwresponses.AutoFromDoc[FindLensKitsResponse],
		&handlers.FindByIDQueryHandler[*appqa.FindLensKitByIDQuery]{Reader: d.ViewReader, View: viewName})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:id", byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary:     "Get a lens kit by id, parts in DESCENDING slot order",
			Description: "The same root and the same source view as /qa/lens-kits, projected into a second collection whose EmbedMany declares .OrderBy(\"slot\").Desc() — the materialized order is a property of the VIEW, not of the data.",
			Tags:        []string{"QA Lens (materialized view-on-view)"},
		},
		fwopenapi.RequirePermission("gadgets:read"))
}

// MountLensBrands registers HOP 0 — the deepest source of the chain. It exists
// because the gadget fixture (the other source this family embeds) exposes no
// update verb: a rename here is the value the suite follows two ripple hops out.
func MountLensBrands(
	app *fiber.App,
	repo persistence.ScopedRepository[*qadomain.LensBrand],
	viewName string,
	d bootstrap.Deps,
) {
	g := app.Group("/qa/lens-brands")
	tags := []string{"QA Lens (materialized view-on-view)"}

	insertH, insertSpec := fwweb.CommandWithBodySpec(d.Pipeline,
		InsertLensBrandRequest{},
		LensBrandWriteResponse{}.FromResult,
		&handlers.InsertCommandHandler[*qadomain.LensBrand, *appqa.InsertLensBrandCommand, appqa.LensBrandResult]{
			Repo: repo,
		}, fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPost, "/", insertH, insertSpec,
		fwopenapi.Doc{Summary: "Create a lens brand", Description: "The deepest root of the materialized chain.", Tags: tags},
		fwopenapi.RequirePermission("gadgets:write"))

	updateH, updateSpec := fwweb.CommandWithBodyIDSpec(d.Pipeline,
		UpdateLensBrandRequest{},
		LensBrandWriteResponse{}.FromResult,
		&handlers.UpdateCommandHandler[*qadomain.LensBrand, *appqa.UpdateLensBrandCommand, appqa.LensBrandResult]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPut, "/:id", updateH, updateSpec,
		fwopenapi.Doc{Summary: "Rename a lens brand (the two-hop trigger)", Description: "One write here must reach `parts[].brand.name` (hop 1) and `kits[].parts[].brand.name` (hop 2), with nothing declared about the chain.", Tags: tags},
		fwopenapi.RequirePermission("gadgets:write"))

	listH, listSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindLensBrandsRequest{},
		fwresponses.AutoFromDoc[FindLensBrandsResponse],
		&handlers.FindByParamsQueryHandler[*appqa.FindLensBrandsQuery]{Reader: d.ViewReader, View: viewName})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/", listH, listSpec,
		fwopenapi.Doc{Summary: "List lens brands", Description: "The source view's own surface — an embedded view stays first-class.", Tags: tags},
		fwopenapi.RequirePermission("gadgets:read"))

	archiveH, archiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.ArchiveCommandHandler[*qadomain.LensBrand, *appqa.ArchiveLensBrandCommand, fwresults.None]{Repo: repo},
		fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/archive", archiveH, archiveSpec,
		fwopenapi.Doc{Summary: "Archive a lens brand", Description: "Archived content is hidden on a default read in EVERY segment that materializes this brand, at any depth, and `?includeArchived=true` reveals it — the rule applies because the brand schema declares DeletedAt.", Tags: tags},
		fwopenapi.RequirePermission("gadgets:archive"))

	unarchiveH, unarchiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.UnarchiveCommandHandler[*qadomain.LensBrand, *appqa.UnarchiveLensBrandCommand, fwresults.None]{Repo: repo},
		fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/unarchive", unarchiveH, unarchiveSpec,
		fwopenapi.Doc{Summary: "Unarchive a lens brand", Tags: tags},
		fwopenapi.RequirePermission("gadgets:archive"))

	deleteH, deleteSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.DeleteCommandHandler[*qadomain.LensBrand, *appqa.DeleteLensBrandCommand, fwresults.None]{Repo: repo},
		fiber.StatusNoContent)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodDelete, "/:id", deleteH, deleteSpec,
		fwopenapi.Doc{Summary: "Hard-delete a lens brand", Description: "The 1:1 segment must become the explicit null at BOTH hops.", Tags: tags},
		fwopenapi.RequirePermission("gadgets:write"))
}

// MountLensParts registers HOP 1 of the materialized view-on-view chain:
// /qa/lens-parts/* over `qa_lens_parts_view`, whose documents carry the LOCAL
// `gadgets` view embedded 1:1 under "gadget".
func MountLensParts(
	app *fiber.App,
	repo persistence.ScopedRepository[*qadomain.LensPart],
	viewName string,
	d bootstrap.Deps,
) {
	g := app.Group("/qa/lens-parts")
	tags := []string{"QA Lens (materialized view-on-view)"}

	insertH, insertSpec := fwweb.CommandWithBodySpec(d.Pipeline,
		InsertLensPartRequest{},
		LensPartWriteResponse{}.FromResult,
		&handlers.InsertCommandHandler[*qadomain.LensPart, *appqa.InsertLensPartCommand, appqa.LensPartResult]{
			Repo: repo,
		}, fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPost, "/",
		insertH, insertSpec,
		fwopenapi.Doc{
			Summary:     "Create a lens part (ParentID to a gadget, ParentID to a kit)",
			Description: "Both foreign keys are plain columns — the write side declares no containment. `gadgetId` is the join the part's own view embeds 1:1 from the LOCAL `gadgets` view; `kitId` is the join the kits view embeds 1:N on.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:write"))

	updateH, updateSpec := fwweb.CommandWithBodyIDSpec(d.Pipeline,
		UpdateLensPartRequest{},
		LensPartWriteResponse{}.FromResult,
		&handlers.UpdateCommandHandler[*qadomain.LensPart, *appqa.UpdateLensPartCommand, appqa.LensPartResult]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPut, "/:id",
		updateH, updateSpec,
		fwopenapi.Doc{
			Summary:     "Replace a lens part (both FKs are movable)",
			Description: "Repointing `gadgetId` must re-resolve the materialized 1:1 segment even though nothing changed on the gadget's side (the framework's post-write repair); repointing `kitId` must move the element out of one kit's array and into another's.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:write"))

	listH, listSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindLensPartsRequest{},
		fwresponses.AutoFromDoc[FindLensPartsResponse],
		&handlers.FindByParamsQueryHandler[*appqa.FindLensPartsQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List lens parts (filter/sort/fields INTO the materialized segment)",
			Description: "Paged read of `qa_lens_parts_view`. A predicate on `gadget.*` SELECTS ROWS — the segment lives in the same document, unlike a composed leg filter which only shapes the segment. `?orderBy=gadget.code` is a first-class sort key; `?fields=label,gadget.name` prunes into the segment.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:read"))

	byIDH, byIDSpec := fwweb.QueryByIDSpec(d.Pipeline,
		FindLensPartByIDRequest{},
		fwresponses.AutoFromDoc[FindLensPartsResponse],
		&handlers.FindByIDQueryHandler[*appqa.FindLensPartByIDQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:id",
		byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary:     "Get a lens part by id (part + its materialized gadget)",
			Description: "The `gadget` sub-document is the LOCAL `gadgets` view materialized into this document by the embed — it carries the gadget's full projection (category/status included), unlike an upstream mirror filtered by its subscription.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:read"))

	archiveH, archiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.ArchiveCommandHandler[*qadomain.LensPart, *appqa.ArchiveLensPartCommand, fwresults.None]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/archive",
		archiveH, archiveSpec,
		fwopenapi.Doc{
			Summary:     "Archive (DeletedAt) a lens part",
			Description: "The part's own document keeps its `deleted_at` (default reads hide it), and the archived element also LEAVES the kit's 1:N segment on a default read — one archived rule for every segment. `?includeArchived=true` brings it back, in the declared order. `DeleteOnArchive()` on the source view is the stronger option: archiving then REMOVES the document for every reader.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:archive"))

	unarchiveH, unarchiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.UnarchiveCommandHandler[*qadomain.LensPart, *appqa.UnarchiveLensPartCommand, fwresults.None]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/unarchive",
		unarchiveH, unarchiveSpec,
		fwopenapi.Doc{
			Summary:     "Unarchive a lens part",
			Description: "Restores the part and converges every materialized copy of it.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:archive"))

	deleteH, deleteSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.DeleteCommandHandler[*qadomain.LensPart, *appqa.DeleteLensPartCommand, fwresults.None]{
			Repo: repo,
		}, fiber.StatusNoContent)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodDelete, "/:id",
		deleteH, deleteSpec,
		fwopenapi.Doc{
			Summary:     "Hard-delete a lens part",
			Description: "Removes the part's own document AND the element from every kit's materialized array.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:write"))
}

// MountLensKits registers HOP 2: /qa/lens-kits/* over `qa_lens_kits_view`,
// whose documents carry the PARTS VIEW embedded 1:N under "parts" — each
// element already carrying the gadget hop 1 materialized into it.
func MountLensKits(
	app *fiber.App,
	repo persistence.ScopedRepository[*qadomain.LensKit],
	viewName string,
	d bootstrap.Deps,
) {
	g := app.Group("/qa/lens-kits")
	tags := []string{"QA Lens (materialized view-on-view)"}

	insertH, insertSpec := fwweb.CommandWithBodySpec(d.Pipeline,
		InsertLensKitRequest{},
		LensKitWriteResponse{}.FromResult,
		&handlers.InsertCommandHandler[*qadomain.LensKit, *appqa.InsertLensKitCommand, appqa.LensKitResult]{
			Repo: repo,
		}, fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPost, "/",
		insertH, insertSpec,
		fwopenapi.Doc{
			Summary:     "Create a lens kit",
			Description: "The kit owns nothing on the write side; its parts reference it by a plain ParentID, and the read model materializes them as a 1:N segment.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:write"))

	updateH, updateSpec := fwweb.CommandWithBodyIDSpec(d.Pipeline,
		UpdateLensKitRequest{},
		LensKitWriteResponse{}.FromResult,
		&handlers.UpdateCommandHandler[*qadomain.LensKit, *appqa.UpdateLensKitCommand, appqa.LensKitResult]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPut, "/:id",
		updateH, updateSpec,
		fwopenapi.Doc{
			Summary:     "Replace a lens kit",
			Description: "A root update must NOT disturb the materialized `parts` segment (field ownership: the embed segments belong to the ripple, not to this write).",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:write"))

	listH, listSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		FindLensKitsRequest{},
		fwresponses.AutoFromDoc[FindLensKitsResponse],
		&handlers.FindByParamsQueryHandler[*appqa.FindLensKitsQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List lens kits (two levels of materialized segments)",
			Description: "Paged read of `qa_lens_kits_view`. Each item carries `parts[]`, and each element carries `parts[].gadget` — the embed-of-embed shape. A `parts.*` predicate selects kits (array matching); `?fields=name,parts.label,parts.gadget.code` prunes two levels down.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:read"))

	byIDH, byIDSpec := fwweb.QueryByIDSpec(d.Pipeline,
		FindLensKitByIDRequest{},
		fwresponses.AutoFromDoc[FindLensKitsResponse],
		&handlers.FindByIDQueryHandler[*appqa.FindLensKitByIDQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodGet, "/:id",
		byIDH, byIDSpec,
		fwopenapi.Doc{
			Summary:     "Get a lens kit by id (kit + parts[] + parts[].gadget)",
			Description: "Proves the chain end to end: renaming a gadget refreshes `parts[].gadget.name` here, two ripple hops away, with nothing declared about the chain.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:read"))

	archiveH, archiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.ArchiveCommandHandler[*qadomain.LensKit, *appqa.ArchiveLensKitCommand, fwresults.None]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/archive",
		archiveH, archiveSpec,
		fwopenapi.Doc{
			Summary:     "Archive (DeletedAt) a lens kit",
			Description: "The kit's own DeletedAt gate hides it from default reads; `?includeArchived=true` returns it with its segments intact.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:archive"))

	unarchiveH, unarchiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.UnarchiveCommandHandler[*qadomain.LensKit, *appqa.UnarchiveLensKitCommand, fwresults.None]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id/unarchive",
		unarchiveH, unarchiveSpec,
		fwopenapi.Doc{
			Summary:     "Unarchive a lens kit",
			Description: "Restores the kit; the materialized segments must survive the round trip.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:archive"))

	deleteH, deleteSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.DeleteCommandHandler[*qadomain.LensKit, *appqa.DeleteLensKitCommand, fwresults.None]{
			Repo: repo,
		}, fiber.StatusNoContent)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodDelete, "/:id",
		deleteH, deleteSpec,
		fwopenapi.Doc{
			Summary:     "Hard-delete a lens kit",
			Description: "Removes the kit document; the parts survive as their own aggregates (no write-side containment), orphaned by ParentID.",
			Tags:        tags,
		},
		fwopenapi.RequirePermission("gadgets:write"))
}
