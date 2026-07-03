//go:build qa

package qafixtures

import (
	"errors"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/domain/qafixtures"
)

// InsertGadgetCustomHandler is the MANUAL counterpart of the Auto
// InsertCommandHandler for Gadget. It performs the same lifecycle by hand and
// attaches the SAME two in-TX hooks — but as closures passed to
// repo.Scope(ctx, opts...) via persistence.WithAfterBegin / WithBeforeCommit,
// instead of relying on the command's provider methods. Mounted on a second
// route (POST /qa/gadgets/custom), it proves hook invariance across the Auto
// and manual paths: both write the same journal rows and both roll back on
// Code == "POISON".
//
// The Journal port arrives by constructor injection here (the composition root
// wires it), in contrast to the Auto path's package-level UseJournal.
type InsertGadgetCustomHandler struct {
	Repo      persistence.ScopedRepository[*qadomain.Gadget]
	Service   domain.Service
	Journal   GadgetJournal
	Publisher GadgetEventPublisher
}

func (h *InsertGadgetCustomHandler) Handle(
	ctx *configuration.AppContext, cmd *InsertGadgetCommand,
) (InsertGadgetResult, error) {
	var zero InsertGadgetResult

	entity, err := cmd.ToEntity(ctx)
	if err != nil {
		return zero, err
	}
	insertable, err := domain.GetInsertable(entity, h.Service, "GetInsertable")
	if err != nil {
		return zero, err
	}

	id, err := h.Repo.Scope(ctx,
		// Slot A — pre-write: journal with no id yet.
		persistence.WithAfterBegin[*qadomain.Gadget](func(
			ctx *configuration.AppContext, _ *qadomain.Gadget, tx persistence.TxHandle,
		) error {
			return h.Journal.Write(ctx, tx, "", "before-write")
		}),
		// Slot D — post-write: journal the generated id, or force a rollback
		// on the poison code.
		persistence.WithBeforeCommit[*qadomain.Gadget](func(
			ctx *configuration.AppContext, g *qadomain.Gadget, id domain.ID, tx persistence.TxHandle,
		) error {
			if g.Code == "POISON" {
				return errors.New("gadget POISON: forced rollback from BeforeCommit closure")
			}
			if err := h.Journal.Write(ctx, tx, id.Value(), "after-write"); err != nil {
				return err
			}
			// Same in-TX publish as the Auto path — proving publish invariance
			// across the Auto and manual handlers. Injected by constructor here.
			return h.Publisher.Publish(ctx, tx, id, GadgetCreatedEvent{
				GadgetID: id.Value(),
				Code:     g.Code,
				Name:     g.Name,
				Category: g.Category,
				Status:   g.Status,
			})
		}),
	).Insert(insertable)
	if err != nil {
		return zero, err
	}

	entity.SetID(id)
	result, err := cmd.FromEntity(ctx, entity)
	if err != nil {
		return zero, err
	}
	return result, nil
}
