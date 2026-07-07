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

// MountItems registers the Item write surface under /qa/items: create (feeds a
// new upstream_items projection doc) + patch-label (mutates a doc so the suite
// can observe the recompose ripple into the shared-base document). No read
// surface: an Item's only read presence is the embedded segment on the
// shared-base view — that is the whole point of the fixture.
func MountItems(
	app *fiber.App,
	repo persistence.ScopedRepository[*qadomain.Item],
	d bootstrap.Deps,
) {
	g := app.Group("/qa/items")

	insertH, insertSpec := fwweb.CommandWithBodySpec(d.Pipeline,
		InsertItemRequest{},
		ItemResponse{}.FromResult,
		&handlers.InsertCommandHandler[*qadomain.Item, *appqa.InsertItemCommand, appqa.ItemResult]{
			Repo: repo,
		}, fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPost, "/",
		insertH, insertSpec,
		fwopenapi.Doc{
			Summary:     "Create an item (external embed source)",
			Description: "Creates a qa_items row. `accountId` is a nullable FK to an account base id: pass it for a 1:N list member (EmbedMany), omit it for the single 1:1 featured item. The write materializes an `upstream_items` projection doc the shared-base view embeds.",
			Tags:        []string{"QA Accounts (shared-base embed)"},
		},
		fwopenapi.RequirePermission("gadgets:write"))

	patchH, patchSpec := fwweb.CommandWithBodyIDSpec(d.Pipeline,
		UpdateItemRequest{},
		ItemResponse{}.FromResult,
		&handlers.PartialUpdateCommandHandler[*qadomain.Item, *appqa.UpdateItemCommand, appqa.ItemResult]{
			Repo: repo,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodPatch, "/:id",
		patchH, patchSpec,
		fwopenapi.Doc{
			Summary:     "Patch an item (label and/or parent FK)",
			Description: "Updates `label` and/or reassigns `accountId`/`catalogId`. A label change ripples the new label into every embedding parent's segments; reassigning the FK MOVES the item — the ripple recomposes both the old and new parent (drop here, appear there) from one event.",
			Tags:        []string{"QA Accounts (shared-base embed)"},
		},
		fwopenapi.RequirePermission("gadgets:write"))

	deleteH, deleteSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.DeleteCommandHandler[*qadomain.Item, *appqa.DeleteItemCommand, fwresults.None]{
			Repo: repo,
		}, fiber.StatusNoContent)
	fwopenapi.Mount(d.OpenAPIRegistry, g, fiber.MethodDelete, "/:id",
		deleteH, deleteSpec,
		fwopenapi.Doc{
			Summary:     "Hard-delete an item",
			Description: "Removes the qa_items row. onUpstreamDelete=cascade drops the upstream_items doc, then the ripple recomposes the parent it belonged to — the item disappears from that parent's Items array.",
			Tags:        []string{"QA Accounts (shared-base embed)"},
		},
		fwopenapi.RequirePermission("gadgets:write"))
}

// InsertItemRequest is the JSON body of POST /qa/items.
type InsertItemRequest struct {
	AccountID *string `json:"accountId,omitempty" example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
	CatalogID *string `json:"catalogId,omitempty" example:"1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"`
	Label     string  `json:"label"               example:"widget-a"`
}

func (r InsertItemRequest) ToCommand() *appqa.InsertItemCommand {
	return &appqa.InsertItemCommand{AccountID: r.AccountID, CatalogID: r.CatalogID, Label: r.Label}
}

// UpdateItemRequest is the JSON body of PATCH /qa/items/:id. Every field is
// optional (partial): `label` renames, `accountId`/`catalogId` reassign (move).
type UpdateItemRequest struct {
	Label     *string `json:"label,omitempty"     example:"widget-a-renamed"`
	AccountID *string `json:"accountId,omitempty"`
	CatalogID *string `json:"catalogId,omitempty"`
}

func (r UpdateItemRequest) ToCommand() *appqa.UpdateItemCommand {
	return &appqa.UpdateItemCommand{Label: r.Label, AccountID: r.AccountID, CatalogID: r.CatalogID}
}

// ItemResponse is the wire shape of a successful item write.
type ItemResponse struct {
	ID        string  `json:"id"`
	AccountID *string `json:"accountId,omitempty"`
	CatalogID *string `json:"catalogId,omitempty"`
	Label     string  `json:"label"`
}

func (ItemResponse) FromResult(r appqa.ItemResult) ItemResponse {
	return ItemResponse{ID: r.ID.String(), AccountID: r.AccountID, CatalogID: r.CatalogID, Label: r.Label}
}
