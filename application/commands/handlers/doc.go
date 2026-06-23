// Package handlers holds the manual command (write) handlers consumed by the
// /showcase/users-custom/* showcase — co-located with the commands they drive
// under application/commands. Each handler implements pipeline.Handler[*Cmd, TRes]
// explicitly — the canonical /users/* surface reuses the framework's generic
// handlers in omnicore/application/handlers (InsertCommandHandler,
// UpdateCommandHandler, etc.), which hide the FindByID → Get* →
// repo.Scope(ctx).Method(valid) → SetID dance behind a type signature. Writing
// the chain by hand is the whole point of the showcase: it documents what the
// canonical wrappers do under the cover.
//
// Its read-side twin is application/queries/handlers.
package handlers
