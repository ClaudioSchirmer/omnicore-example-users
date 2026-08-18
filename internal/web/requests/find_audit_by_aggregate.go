package requests

import (
	"time"

	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"
	"github.com/google/uuid"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
)

// auditEntityType is the only auditable aggregate this service knows
// about today. Hardcoded here at the wire boundary (rather than baked
// into the Query) so a future aggregate is a one-place edit: either lift
// it onto a `?entityType=` query parameter on this DTO or mount a
// second route per aggregate type. The application layer stays generic.
const auditEntityType = "User"

// FindAuditByAggregateRequest binds the :aggregateId URL segment via
// path tag. The framework's BindPath helper populates AggregateID from
// c.Params("aggregateId") before the route dispatches. The field is
// typed uuid.UUID so a malformed segment (e.g. "not-a-uuid") is rejected
// upfront with the canonical 400 SchemaViolationNotification envelope —
// without it, the malformed string would reach the driver and surface as a
// 500 InternalServerErrorNotification from the Result.Exception path.
//
// Any unknown query string keys are rejected at the openapi.Mount layer
// (no allowlist tags declared today; if filters are added later they go
// via `query:`/`filter:` tags identical to the existing read DTOs).
type FindAuditByAggregateRequest struct {
	AggregateID uuid.UUID `path:"aggregateId" example:"7b3c1f10-3c7e-4a8d-9f0e-9d2a8e6d4b51"`
}

// ToQuery is the canonical web → application boundary mapper. Stays
// body-only: no AppContext consumed here. EntityType is hardcoded
// "User" — see auditEntityType above for the extension story.
// AggregateID is stringified because audit.FindByAggregate accepts a
// string (the audit_events.aggregate_id column is UUID but the helper's
// signature stays string-typed so callers that hold the id as a slog
// header value can pass it directly).
func (r FindAuditByAggregateRequest) ToQuery() *queries.FindAuditByAggregateQuery {
	return &queries.FindAuditByAggregateQuery{
		EntityType:  auditEntityType,
		AggregateID: r.AggregateID.String(),
	}
}

// ─── OUTPUT ─────────────────────────────────────────────────────────────────

// FindAuditByAggregateResponse is the wire projection of one audit timeline
// row, mapped from the application Result by FromResult below. The service
// OWNS this shape: the framework's audit.AuditEvent is an infrastructure
// record, so exposing it directly would hand the wire contract to the
// framework's release cycle. Field labels arrive already rendered in the
// actor's locale (the handler resolves the catalog key before building the
// Result).
type FindAuditByAggregateResponse struct {
	fwresponses.Auto
	ThreadID    string         `json:"threadId"`
	TraceID     string         `json:"traceId,omitempty"`
	EntityType  string         `json:"entityType"`
	EntityID    string         `json:"entityId"`
	Verb        string         `json:"verb"`
	ActionName  string         `json:"actionName"`
	Kind        string         `json:"kind"`
	Actor       string         `json:"actor,omitempty"`
	ActorIssuer string         `json:"actorIssuer,omitempty"`
	ActorClaims map[string]any `json:"actorClaims,omitempty"`
	TenantID    string         `json:"tenantId,omitempty"`
	DateTime    time.Time      `json:"dateTime"`
	Snapshot    map[string]any `json:"snapshot,omitempty"`

	Changes  []AuditFieldChangeOutput           `json:"changes,omitempty"`
	Children map[string][]AuditChildEventOutput `json:"children,omitempty"`
}

// AuditFieldChangeOutput is one field diff on a kind=delta event.
type AuditFieldChangeOutput struct {
	Field      string `json:"field"`
	FieldLabel string `json:"fieldLabel,omitempty"`
	From       any    `json:"from"`
	To         any    `json:"to"`
}

// AuditChildEventOutput is one cascade entry under children[typeName].
type AuditChildEventOutput struct {
	ID       string                   `json:"id,omitempty"`
	Op       string                   `json:"op"`
	Snapshot map[string]any           `json:"snapshot,omitempty"`
	Changes  []AuditFieldChangeOutput `json:"changes,omitempty"`
}

// FromResult is the wire mapping seat, delegating to the generic name-based
// mapper (the Response opts in by embedding fwresponses.Auto) — the same seat every other read Response carries.
func (FindAuditByAggregateResponse) FromResult(r queries.FindAuditByAggregateResult) FindAuditByAggregateResponse {
	return fwresponses.AutoFromResult[FindAuditByAggregateResponse](r)
}
