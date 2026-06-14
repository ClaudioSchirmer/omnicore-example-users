package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
)

// InsertUserCustomCommandHandler is the manual counterpart to the framework's
// generic InsertCommandHandler. Same lifecycle the Auto handler performs,
// written out so a reader can trace each step: hydrate entity from Command →
// run domain validation via GetInsertable → delegate the write to the
// persistence.Writer port (carrying the new lifecycle-hook variadic) →
// propagate the assigned ID back onto the entity → project to
// commands.UserCustomResult so the wire layer receives an application-layer
// DTO instead of the raw domain entity.
//
// The projection step (cmd.FromEntity) is the manual analogue of the
// framework's Auto handler Cmd-side projection: it decouples the wire
// response shape from the domain entity shape so renames or new domain
// fields don't leak straight into the HTTP contract.
//
// In-TX side effects would land as trailing persistence.WriteOption[*User]
// options on the Repo.Insert call — same surface the Auto handler reaches via
// the Cmd's optional AfterBegin / BeforeCommit provider methods.
type InsertUserCustomCommandHandler struct {
	Repo    UserCustomRepository
	Service domain.Service
}

func (h *InsertUserCustomCommandHandler) Handle(
	ctx *configuration.AppContext, cmd *commands.InsertUserCustomCommand,
) (commands.UserCustomResult, error) {
	user := cmd.ToEntity(ctx)

	insertable, err := domain.GetInsertable(user, h.Service, "GetInsertable")
	if err != nil {
		return commands.UserCustomResult{}, err
	}

	id, err := h.Repo.Insert(ctx, insertable)
	if err != nil {
		return commands.UserCustomResult{}, err
	}

	user.SetID(id)
	return cmd.FromEntity(ctx, user), nil
}

// ─── LIFECYCLE HOOKS — FICTITIOUS EXAMPLE ───────────────────────────────────
//
// The block below is documentation, not active code. It shows how a manual
// handler attaches both in-TX lifecycle hooks via the explicit functional
// option surface — symmetric with the Auto path's Cmd.AfterBegin and
// Cmd.BeforeCommit methods but expressed as closures at the call site.
// Same atomicity, same firing positions: WithAfterBegin → slot A (AFTER
// BEGIN, BEFORE any framework write); WithBeforeCommit → slot D (AFTER
// data + outbox + audit, BEFORE COMMIT). Both are independently optional —
// pass only the closures the use case needs. Non-nil error from either →
// ROLLBACK; NotificationCarrier identity propagates verbatim through the
// persister to pipeline.Run.
//
// ARCHITECTURAL NOTE — application stays SQL-free.
// The closures below receive a persistence.TxHandle so they can compose
// with the framework's TX without importing pgx. That does NOT authorize
// embedding SQL strings or table names here: the moment a handler writes
// `tx.Exec("INSERT INTO foo …")` the application layer regains a
// dependency on the database schema and the DDD boundary collapses.
//
// The canonical shape for an in-TX side effect is:
//
//   1. Declare a port in application/ (or domain/) — pure Go interface:
//        type NotificationOutbox interface {
//            EnqueueActivationRequested(ctx *configuration.AppContext,
//                tx persistence.TxHandle, userID domain.ID) error
//        }
//
//   2. Implement it in infra/ — the adapter owns the SQL + table name:
//        func (NotificationOutboxPG) EnqueueActivationRequested(ctx, tx, id) error {
//            _, err := tx.Exec(ctx, `INSERT INTO notification_outbox …`, …)
//            return err
//        }
//
//   3. Inject the port on the handler (constructor / wire) and call it
//      from inside the closure — same TX, same atomicity, no SQL in
//      application.
//
// The placeholder below illustrates the call shape on the manual path.
/*
id, err := h.Repo.Insert(ctx, insertable,
	persistence.WithAfterBegin[*appdomain.User](func(
		ctx *configuration.AppContext,
		u *appdomain.User,
		tx persistence.TxHandle,
	) error {
		// Slot A — pre-write. Useful for in-TX state reads, row-level locks,
		// pre-write invariants depending on the TX snapshot. The closure
		// calls a port; the port's adapter in infra/ owns the SQL.
		// return h.QuotaPort.AssertTenantQuota(ctx, tx, u.TenantID)
		return nil
	}),
	persistence.WithBeforeCommit[*appdomain.User](func(
		ctx *configuration.AppContext,
		u *appdomain.User,
		id domain.ID,
		tx persistence.TxHandle,
	) error {
		// Slot D — post-write. Useful for companion outbox events,
		// denormalization rows, cross-table updates — atomic with the
		// framework's own writes. Same rule: call a port, never inline SQL.
		// return h.NotificationOutbox.EnqueueActivationRequested(ctx, tx, id)
		return nil
	}),
)
*/
