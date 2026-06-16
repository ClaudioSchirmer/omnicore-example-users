package queries

import (
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
)

// FindAuditByAggregateQuery is the application-layer transport for
// GET /audit/:aggregateId. The handler dispatches to
// audit.FindByAggregate(ctx, pg, EntityType, AggregateID) — the canonical
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
