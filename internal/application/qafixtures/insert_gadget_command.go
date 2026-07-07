//go:build qa

// Package qafixtures (application layer) holds the QA-only command/query
// vocabulary for the Gadget aggregate. Gated behind the `qa` build tag.
package qafixtures

import (
	"errors"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// ─── Lifecycle-hook side-effect port ────────────────────────────────────────

// GadgetJournal is the in-TX side-effect port the lifecycle hooks call. The
// TxHandle is a sealed marker with no public methods; the adapter (in
// infra/qafixtures) recovers the neutral Tx via fwdb.UnwrapTx and owns the SQL
// + table name — the application layer never pronounces SQL. gadgetID is empty
// on the pre-write (AfterBegin) call and populated on the post-write
// (BeforeCommit) call. phase is a free-form marker ("before-write" /
// "after-write") written to the journal row.
type GadgetJournal interface {
	Write(ctx *configuration.AppContext, tx persistence.TxHandle, gadgetID, phase string) error
}

// journal is the wire-time-injected adapter the Auto command's hook methods
// call. The Auto path builds the command from the request DTO (ToCommand),
// which has no injection point for an infra port, so the port lands here as a
// package singleton set once at boot via UseJournal. The MANUAL path
// (InsertGadgetCustomHandler) receives its port by constructor injection
// instead — the two mechanisms prove hook invariance regardless of how the
// port reaches the hook.
var journal GadgetJournal

// UseJournal injects the journal adapter used by the Auto command hooks. Called
// exactly once by the GadgetFeature at boot.
func UseJournal(j GadgetJournal) { journal = j }

// ─── Command ─────────────────────────────────────────────────────────────────

// InsertGadgetCommand is the application-layer "create Gadget" use case. Unlike
// the SharedBase-backed InsertUserCommand (which declares ApplyTo), a flat
// aggregate declares ToEntity/FromEntity per pipeline.InsertCommand — the Auto
// handlers.InsertCommandHandler hydrates a fresh entity and projects the result.
type InsertGadgetCommand struct {
	pipeline.CommandBase
	Code     string
	Name     string
	Category string
	Status   string
}

// ToEntity hydrates a fresh Gadget from the command (pure mapper).
func (c *InsertGadgetCommand) ToEntity(_ *configuration.AppContext) (*qadomain.Gadget, error) {
	return &qadomain.Gadget{
		Code:     c.Code,
		Name:     c.Name,
		Category: c.Category,
		Status:   c.Status,
	}, nil
}

// FromEntity is the symmetric inverse — Entity → Result — called after Insert
// + SetID.
func (c *InsertGadgetCommand) FromEntity(_ *configuration.AppContext, g *qadomain.Gadget) (InsertGadgetResult, error) {
	return InsertGadgetResult{
		ID:       *g.GetID(),
		Code:     g.Code,
		Name:     g.Name,
		Category: g.Category,
		Status:   g.Status,
	}, nil
}

// InsertGadgetResult is the application-layer projection returned by FromEntity.
type InsertGadgetResult struct {
	ID       domain.ID
	Code     string
	Name     string
	Category string
	Status   string
}

// ─── Lifecycle hooks — ACTIVE (the whole point of this fixture) ─────────────

// AfterBegin fires at slot A — AFTER BEGIN, BEFORE any framework write. The row
// does not exist yet, so it journals with an empty id under the "before-write"
// phase. The Auto InsertCommandHandler auto-detects this method via type
// assertion against persistence.AfterBeginHookProvider[*Gadget].
func (c *InsertGadgetCommand) AfterBegin(
	ctx *configuration.AppContext, _ *qadomain.Gadget, tx persistence.TxHandle,
) error {
	return journal.Write(ctx, tx, "", "before-write")
}

// BeforeCommit fires at slot D — AFTER the data + outbox + audit writes, BEFORE
// COMMIT. It journals the generated id under the "after-write" phase.
//
// FORCED ROLLBACK: when the incoming Gadget.Code == "POISON" it returns a
// non-nil error, which rolls the whole TX back — proving the journal rows AND
// the gadget row all vanish together. A plain error is enough to trigger the
// rollback; it surfaces as a 500 envelope (the rollback is what QA asserts).
func (c *InsertGadgetCommand) BeforeCommit(
	ctx *configuration.AppContext, g *qadomain.Gadget, id domain.ID, tx persistence.TxHandle,
) error {
	if g.Code == "POISON" {
		return errors.New("gadget POISON: forced rollback from BeforeCommit hook")
	}
	if err := journal.Write(ctx, tx, id.Value(), "after-write"); err != nil {
		return err
	}
	// Publish the integration event in the SAME TX (after the journal
	// after-write, never on the POISON path). A publish failure — or the
	// forced rollback above — reverts the integration_events row together with
	// the gadget + journal rows.
	return publisher.Publish(ctx, tx, id, GadgetCreatedEvent{
		GadgetID: id.Value(),
		Code:     g.Code,
		Name:     g.Name,
		Category: g.Category,
		Status:   g.Status,
	})
}

// Compile-time guards against typos on the provider method signatures + the
// InsertCommand contract.
var (
	_ pipeline.InsertCommand[*qadomain.Gadget, InsertGadgetResult] = (*InsertGadgetCommand)(nil)
	_ persistence.AfterBeginHookProvider[*qadomain.Gadget]         = (*InsertGadgetCommand)(nil)
	_ persistence.BeforeCommitHookProvider[*qadomain.Gadget]       = (*InsertGadgetCommand)(nil)
)
