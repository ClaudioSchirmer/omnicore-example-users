package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// InsertUserCustomCommandHandler is the manual counterpart to the framework's
// generic SharedBaseInsertCommandHandler — the User is SharedBase-backed, so a
// POST is an UPSERT. Same lifecycle the Auto handler performs, written out so a
// reader can trace each step:
//
//  1. Apply the request onto a throwaway entity to read the natural key
//     (Document) — cmd.ApplyTo is a pure mapper, so this is free.
//  2. Load the existing shared Person identity by that key — its shared fields
//     plus its addresses as Constructor items (existed=false → cold insert).
//  3. On a warm upsert, apply the request again onto the loaded identity (so
//     u.AddAddress dedups the request's addresses against the loaded ones) and
//     switch the actionName to "GetUpsertable" — the framework's persister
//     guard refuses a blind insert against a pre-existing identity, and
//     BuildRules can branch on the path.
//  4. Validate via GetInsertable → bind the request scope and Insert through the
//     pure domain.Writer → propagate the assigned ID → project to
//     commands.UserCustomResult.
//
// In-TX side effects would land as persistence.WriteOption[*User] options on
// the Repo.Scope(ctx, opts...) call — same surface the Auto handler reaches via
// the Cmd's optional AfterBegin / BeforeCommit provider methods.
type InsertUserCustomCommandHandler struct {
	Repo    ScopedUserRepository
	Service domain.Service
}

func (h *InsertUserCustomCommandHandler) Handle(
	ctx *configuration.AppContext, cmd *commands.InsertUserCustomCommand,
) (commands.UserCustomResult, error) {
	// Step 1 — read the natural key off a throwaway entity.
	fresh := &appdomain.User{}
	if err := cmd.ApplyTo(ctx, fresh); err != nil {
		return commands.UserCustomResult{}, err
	}

	// Step 2 — load the existing shared identity by the natural key.
	user, existed, err := h.Repo.LoadForSharedBaseInsert(ctx, fresh)
	if err != nil {
		return commands.UserCustomResult{}, err
	}

	// Step 3 — warm upsert: re-apply onto the loaded identity, flip the action.
	action := "GetInsertable"
	if existed {
		if err := cmd.ApplyTo(ctx, user); err != nil {
			return commands.UserCustomResult{}, err
		}
		action = "GetUpsertable"
	}

	// Step 4 — validate, persist, project.
	insertable, err := domain.GetInsertable(user, h.Service, action)
	if err != nil {
		return commands.UserCustomResult{}, err
	}

	repo := h.Repo.Scope(ctx)
	id, err := repo.Insert(insertable)
	if err != nil {
		return commands.UserCustomResult{}, err
	}

	user.SetID(id)
	result, err := cmd.FromEntity(ctx, user)
	if err != nil {
		return commands.UserCustomResult{}, err
	}
	return result, nil
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
// TxHandle is a sealed marker — it carries NO public methods. The closure
// cannot write SQL through it. The canonical (and only) shape for an
// in-TX side effect is:
//
//   1. Declare a port in application/ (or domain/) — pure Go interface
//      whose method receives a persistence.TxHandle parameter:
//        type NotificationOutbox interface {
//            EnqueueActivationRequested(ctx *configuration.AppContext,
//                tx persistence.TxHandle, userID domain.ID) error
//        }
//
//   2. Implement the port in infra/ — the adapter recovers the neutral
//      infra.Tx via fwdb.UnwrapTx(tx) and owns the SQL + table name
//      (render placeholders via tx.Dialect() so it runs on any engine):
//        func (NotificationOutboxAdapter) EnqueueActivationRequested(
//            ctx *configuration.AppContext, tx persistence.TxHandle, id domain.ID,
//        ) error {
//            x := fwdb.UnwrapTx(tx)
//            return x.Exec(ctx, `INSERT INTO notification_outbox …`, …)
//        }
//
//   3. Inject the port on the handler (constructor / wire) and call it
//      from inside the closure — same TX as the framework's writes,
//      atomic by construction, application layer never pronounces SQL.
//
// The placeholder below illustrates the call shape on the manual path.
/*
id, err := h.Repo.Scope(ctx,
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
).Insert(insertable)
*/
