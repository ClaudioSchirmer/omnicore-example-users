package requests

import (
	"github.com/ClaudioSchirmer/omnicore/infra/audit"
	"github.com/google/uuid"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
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

// FindAuditByAggregateResponse is a type alias over the framework's
// audit.AuditEvent slice. The struct already carries the wire-correct
// JSON tags (top-level fields + nested Children + Changes with
// FieldLabel) so reprojecting it through a Response twin would be
// duplication for zero gain. The handler renders FieldLabelKey →
// FieldLabel via audit.RenderLabels before the route serializes, so the
// wire shape matches what the notification surface publishes.
type FindAuditByAggregateResponse = []*audit.AuditEvent
