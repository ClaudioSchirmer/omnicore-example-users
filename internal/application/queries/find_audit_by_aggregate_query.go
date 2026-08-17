package queries

import (
	"time"

	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
)

// FindAuditByAggregateQuery is the application-layer transport for
// GET /audit/:aggregateId. The handler dispatches to
// audit.FindByAggregate(ctx, eng, EntityType, AggregateID) — the canonical
// timeline reader served by the audit_events_entity_timeline_idx
// (entity_type, aggregate_id, occurred_at DESC).
//
// EntityType is hardcoded to "User" by the wire boundary
// (FindAuditByAggregateRequest.ToQuery) since this service has one
// auditable aggregate. When a future aggregate is added, lift the
// hardcoding into a query parameter on the wire DTO + ToQuery — the
// Query type itself already exposes both fields so no application-side
// rewrite is required.
//
// Note: a sibling FindAuditByID(ctx, exec, uuid) helper exists in
// infra/audit/reader.go for the forensic single-row lookup when an audit
// row id is known from the slog echo. This endpoint deliberately
// exposes only the timeline read — the by-id variant has a different
// access-control story (no aggregate scope = no resource owner check)
// and would need its own gate.
type FindAuditByAggregateQuery struct {
	pipeline.QueryBase
	EntityType  string
	AggregateID string
}

// ─── RESULT ─────────────────────────────────────────────────────────────────

// FindAuditByAggregateResult is the application-layer Result of one audit
// timeline row. The service OWNS this shape — the framework's audit.AuditEvent
// is an infrastructure record, not this service's wire contract, so the
// timeline can be narrowed, renamed or versioned here without a framework
// change. Tagless, like every Result; the web Response owns the wire names.
type FindAuditByAggregateResult struct {
	ThreadID    string
	TraceID     string
	EntityType  string
	EntityID    string
	Verb        string
	ActionName  string
	Kind        string
	Actor       string
	ActorIssuer string
	// ActorClaims carries the JWT claims the auth.auditClaims allowlist
	// admitted — the framework filters them before the record is written, so
	// this surface never widens what the audit trail already decided.
	ActorClaims map[string]any
	TenantID    string
	DateTime    time.Time
	Snapshot    map[string]any
	Changes     []AuditFieldChangeResult
	Children    map[string][]AuditChildResult
}

// AuditFieldChangeResult is one field diff on a kind=delta event. FieldLabel
// carries the label ALREADY rendered in the actor's locale — the handler
// resolves the catalog key before building the Result, so every surface
// receives the translated string.
type AuditFieldChangeResult struct {
	Field      string
	FieldLabel string
	From       any
	To         any
}

// AuditChildResult is one cascade entry under Children[typeName].
type AuditChildResult struct {
	ID       string
	Op       string
	Snapshot map[string]any
	Changes  []AuditFieldChangeResult
}
