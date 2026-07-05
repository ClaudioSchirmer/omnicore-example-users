//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/domain/qafixtures"
)

// ─── Item commands ───────────────────────────────────────────────────────────

// InsertItemCommand creates an Item — a flat insert whose only purpose is to
// feed the `upstream_items` projection the shared-base view embeds.
type InsertItemCommand struct {
	pipeline.CommandBase
	AccountID *string
	CatalogID *string
	Label     string
}

func (c *InsertItemCommand) ToEntity(_ *configuration.AppContext) (*qadomain.Item, error) {
	return &qadomain.Item{AccountID: c.AccountID, CatalogID: c.CatalogID, Label: c.Label}, nil
}

func (c *InsertItemCommand) FromEntity(_ *configuration.AppContext, i *qadomain.Item) (ItemResult, error) {
	return ItemResult{ID: *i.GetID(), AccountID: i.AccountID, CatalogID: i.CatalogID, Label: i.Label}, nil
}

// UpdateItemCommand is a PATCH driving two ripple levers:
//   - Label: a label change flows outbox → qa_items.events → upstream_items →
//     recompose of every view embedding that collection, so the parent
//     document's FeaturedItem/Items segments pick up the new label with no write
//     against the parent itself.
//   - AccountID / CatalogID: reassigning the 1:N FK MOVES the item between
//     parents — the upstream ripple must recompose BOTH the old and the new
//     parent (drop here, appear there) from a single event.
//
// Non-nil fields are applied; a nil field is left unchanged (partial semantics).
type UpdateItemCommand struct {
	pipeline.CommandBaseWithID
	Label     *string
	AccountID *string
	CatalogID *string
}

func (c *UpdateItemCommand) ApplyPartiallyTo(_ *configuration.AppContext, i *qadomain.Item) error {
	if c.Label != nil {
		i.Label = *c.Label
	}
	if c.AccountID != nil {
		i.AccountID = c.AccountID
	}
	if c.CatalogID != nil {
		i.CatalogID = c.CatalogID
	}
	return nil
}

func (c *UpdateItemCommand) FromEntity(_ *configuration.AppContext, i *qadomain.Item) (ItemResult, error) {
	return ItemResult{ID: *i.GetID(), AccountID: i.AccountID, CatalogID: i.CatalogID, Label: i.Label}, nil
}

// DeleteItemCommand hard-deletes an Item — the lever for the delete ripple: the
// item drops from its parent's Items array (onUpstreamDelete=cascade removes the
// upstream_items doc, then the ripple recomposes the parent it belonged to).
type DeleteItemCommand struct{ pipeline.CommandBaseWithID }

func (*DeleteItemCommand) ApplyTo(_ *configuration.AppContext, _ *qadomain.Item) error {
	return nil
}

func (*DeleteItemCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.Item) (fwresults.None, error) {
	return fwresults.None{}, nil
}

// ItemResult is the application-layer projection shared by both item commands.
type ItemResult struct {
	ID        domain.ID
	AccountID *string
	CatalogID *string
	Label     string
}

var (
	_ pipeline.InsertCommand[*qadomain.Item, ItemResult]        = (*InsertItemCommand)(nil)
	_ pipeline.PartialUpdateCommand[*qadomain.Item, ItemResult] = (*UpdateItemCommand)(nil)
)
