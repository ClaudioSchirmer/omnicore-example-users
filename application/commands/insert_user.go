package commands

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	"github.com/ClaudioSchirmer/omnicore/domain"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/dtos"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// ─── INPUT ──────────────────────────────────────────────────────────────────

// InsertUserCommand is the application-layer vocabulary for the "create User"
// use case. No JSON tags (wire format lives in web/requests/InsertUserRequest);
// types mirror the Request 1:1.
type InsertUserCommand struct {
	pipeline.CommandBase
	Name      string
	Email     string
	Phone     *string
	Addresses []dtos.AddressInput
}

// ToEntity receives *AppContext so the command can translate identity-derived
// claims (JWT subject, tenant id, custom claims) into business-named fields on
// the entity. Today this showcase doesn't consume ctx — the framework wires
// the parameter so a future authz field on User would be populated here
// without touching the handler/wrapper signatures.
func (c InsertUserCommand) ToEntity(_ *configuration.AppContext) *appdomain.User {
	u := &appdomain.User{
		Name:  c.Name,
		Email: c.Email,
		Phone: c.Phone,
	}
	// Command speaks domain vocabulary to the root, not the framework's typed
	// primitives. User.AddAddress runs aggregate-spanning invariants
	// (duplicate detection) and delegates to AddAggregateChild (which enforces
	// the type-guard via AggregateChildren()).
	for _, a := range c.Addresses {
		u.AddAddress(a.ToAddress(), nil)
	}
	return u
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FromEntity is the symmetric inverse of ToEntity — Entity → Result. Lives on
// the Command (not on Result) so both boundaries of the use case sit side by
// side under the Cmd's surface. Receives ctx for symmetry with ToEntity; a
// future authz overlay (project only fields the requesting principal is
// allowed to see) would consume it here. The framework calls this AFTER
// orchestrator.Insert + SetID.
func (c InsertUserCommand) FromEntity(_ *configuration.AppContext, u *appdomain.User) InsertUserResult {
	return InsertUserResult{
		ID:    *u.GetID(),
		Name:  u.Name,
		Email: u.Email,
		Phone: u.Phone,
	}
}

// InsertUserResult is the application-layer projection returned by FromEntity.
// Pure data shape — no methods, no behavior. The wire layer maps this to JSON
// via InsertUserResponse.FromResult (also pure data mapping). Result stays in
// application/ (no JSON tags); Response stays in web/ (with JSON tags).
type InsertUserResult struct {
	ID    domain.ID
	Name  string
	Email string
	Phone *string
}

// ─── LIFECYCLE HOOKS — FICTITIOUS EXAMPLE ───────────────────────────────────
//
// The block below is documentation, not active code. It shows how this Cmd
// would declare the two in-TX lifecycle hook methods on the canonical Auto
// path. The Auto InsertCommandHandler detects each method via type assertion
// against persistence.AfterBeginHookProvider[*User] (slot A — fires AFTER
// BEGIN, BEFORE any framework write) and persistence.BeforeCommitHookProvider[*User]
// (slot D — fires AFTER data + outbox + audit, BEFORE COMMIT). Both are
// independently optional; declare only what's needed. Non-nil error from
// either → ROLLBACK; NotificationCarrier identity propagates verbatim to
// pipeline.Run so a typed envelope reaches the wire instead of 500.
//
// AfterBegin's signature has no id parameter (the row hasn't been written
// yet — for verbs other than Insert the id is available via t.GetID()).
// BeforeCommit receives the generated id (populated for all 5 write verbs).
//
// TxHandle is a sealed marker — it carries NO public methods. The hook
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
//   2. Implement the port in infra/ — the adapter recovers the pgx.Tx
//      via fwinfra.UnwrapPgxTx(tx) and owns the SQL + table name:
//        func (NotificationOutboxPG) EnqueueActivationRequested(
//            ctx *configuration.AppContext, tx persistence.TxHandle, id domain.ID,
//        ) error {
//            pgxTx := fwinfra.UnwrapPgxTx(tx)
//            _, err := pgxTx.Exec(ctx, `INSERT INTO notification_outbox …`, …)
//            return err
//        }
//
//   3. Inject the port on the Cmd (constructor / wire) and call it from
//      the hook — same TX as the framework's writes, atomic by
//      construction, application layer never pronounces SQL.
//
// The placeholder below illustrates the call shape on the Auto path.
/*
// Slot A — pre-write hook. Useful for: in-TX state reads (quota checks,
// row-level locks), pre-write invariants that depend on a TX-snapshot
// read, metrics emission, span enrichment. The hook calls a port; the
// port's adapter owns whatever SQL the side effect needs.
func (c InsertUserCommand) AfterBegin(
	ctx *configuration.AppContext,
	u *appdomain.User,
	tx persistence.TxHandle,
) error {
	// Example: enforce a quota check that depends on TX-snapshot state.
	// return c.QuotaPort.AssertTenantQuota(ctx, tx, u.TenantID)
	return nil
}

// Slot D — post-write hook. Useful for: writing companion outbox events,
// denormalization rows, cross-table updates — all atomically with the
// aggregate write. The framework's canonical outbox row already shipped a
// few microseconds before this hook fires; any extra row added here will
// COMMIT (or ROLLBACK) together with it.
func (c InsertUserCommand) BeforeCommit(
	ctx *configuration.AppContext,
	u *appdomain.User,
	id domain.ID,
	tx persistence.TxHandle,
) error {
	// Example: emit a companion integration event via a port. The adapter
	// in infra/ owns the table name and the SQL.
	// return c.NotificationOutbox.EnqueueActivationRequested(ctx, tx, id)
	return nil
}

// Compile-time guards against typos on the provider method signatures —
// recommended boilerplate at the bottom of any Cmd file declaring
// AfterBegin / BeforeCommit. Drop the guard for whichever slot the Cmd
// does not declare.
var (
	_ persistence.AfterBeginHookProvider[*appdomain.User]   = (*InsertUserCommand)(nil)
	_ persistence.BeforeCommitHookProvider[*appdomain.User] = (*InsertUserCommand)(nil)
)
*/
