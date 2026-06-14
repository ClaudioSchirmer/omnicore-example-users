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
// To activate: uncomment + add imports for "omnicore/application/persistence".
// The configuration + appdomain + domain imports are already present above.
/*
// Slot A — pre-write hook. Useful for: in-TX state reads (quota checks,
// row-level locks via SELECT ... FOR UPDATE), pre-write invariants that
// depend on a TX-snapshot read, metrics emission, span enrichment.
func (c InsertUserCommand) AfterBegin(
	ctx *configuration.AppContext,
	u *appdomain.User,
	tx persistence.TxHandle,
) error {
	var serverNow string
	if err := tx.QueryRow(ctx, `SELECT NOW()::text`).Scan(&serverNow); err != nil {
		return err
	}
	return nil
}

// Slot D — post-write hook. Useful for: writing companion outbox events,
// denormalization rows, cross-table updates — all atomically with the
// aggregate write. The framework's canonical outbox row already shipped a
// few microseconds before this hook fires; the extra row added here will
// COMMIT (or ROLLBACK) together with it.
func (c InsertUserCommand) BeforeCommit(
	ctx *configuration.AppContext,
	u *appdomain.User,
	id domain.ID,
	tx persistence.TxHandle,
) error {
	_, err := tx.Exec(ctx,
		`INSERT INTO outbox (aggregate_type, event_type, aggregate_id, payload, created_at)
		 VALUES ($1, $2, $3, $4, NOW())`,
		"users", "UserActivationRequired", id.String(),
		[]byte(`{"user_id":"`+id.String()+`"}`),
	)
	return err
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
