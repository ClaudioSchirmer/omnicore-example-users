package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/audit"
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/translation"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
)

// FindAuditByAggregateQueryHandler is the manual application handler for
// GET /audit/:aggregateId. The framework's Auto query handlers
// (FindByIDQueryHandler / FindByParamsQueryHandler) are not reusable here
// because audit reads happen against the relational backend (the audit_events table),
// not against a Mongo view — the Auto handlers dispatch through
// queries.ViewReader which only knows the Mongo surface.
//
// PRECONDITION — audit destinations must include `database`. The
// handler reads from the `audit_events` table; rows only land there
// when `audit.destinations` in microservice.<profile>.yaml includes
// `database` (the default in the example service). If a deploy ships
// with `destinations: [slog]` (echo-only) or `destinations: []`
// (disabled), this handler will return an empty timeline for every
// aggregate — there is no row to read. Operators who keep audit on
// slog/ELK and want to translate the JSON elsewhere should call
// audit.RenderLabels (typed *AuditEvent) or audit.RenderLabelsInJSON
// (map[string]any) directly against the parsed log line — the
// translation primitives are independent of the storage.
//
// The handler:
//
//  1. Calls audit.FindByAggregate(ctx, h.Pool, q.EntityType,
//     q.AggregateID) — the canonical reader served by the
//     audit_events_entity_timeline_idx (newest first).
//  2. For each returned *AuditEvent, calls audit.RenderLabels(ev,
//     h.Translator, ctx.Language()) so the wire envelope carries
//     `fieldLabel` rendered in the actor's locale (PT-BR / ENG / ESP /
//     FRA / DEU / ITA / NLD) instead of the raw `fieldLabelKey`.
//     Matches the framework convention: backend translates structured
//     output for every channel — HTTP, e-mail, audit. The frontend
//     handles its own static i18n (form labels) but does not need to
//     translate audit field identifiers.
//  3. Maps each event into the service-owned
//     appqueries.FindAuditByAggregateResult — the application Result every
//     read handler returns. The framework's AuditEvent is an infrastructure
//     record; projecting it here keeps the wire shape the SERVICE's to
//     narrow, rename or version, exactly like every other read.
//
// Returns an empty slice + nil error when the aggregate has no audit
// rows (created before audit was enabled, destinations excluded
// `database`, or simply never written to). The route emits a 200 with
// `data: []` in that case — same shape a populated read produces.
type FindAuditByAggregateQueryHandler struct {
	Reader     audit.Reader
	Translator *translation.Translator
}

func (h *FindAuditByAggregateQueryHandler) Handle(
	ctx *configuration.AppContext, q *appqueries.FindAuditByAggregateQuery,
) ([]appqueries.FindAuditByAggregateResult, error) {
	events, err := h.Reader.FindByAggregate(ctx, q.EntityType, q.AggregateID)
	if err != nil {
		return nil, err
	}
	lang := ctx.Language()
	out := make([]appqueries.FindAuditByAggregateResult, 0, len(events))
	for _, ev := range events {
		audit.RenderLabels(ev, h.Translator, lang)
		out = append(out, auditResultOf(ev))
	}
	return out, nil
}

// auditResultOf projects one framework audit record into the service-owned
// Result. Labels are already rendered in the actor's locale by the caller.
func auditResultOf(ev *audit.AuditEvent) appqueries.FindAuditByAggregateResult {
	r := appqueries.FindAuditByAggregateResult{
		ThreadID:    ev.ThreadID,
		TraceID:     ev.TraceID,
		EntityType:  ev.EntityType,
		EntityID:    ev.EntityID,
		Verb:        ev.Verb,
		ActionName:  ev.ActionName,
		Kind:        ev.Kind,
		Actor:       ev.Actor,
		ActorIssuer: ev.ActorIssuer,
		ActorClaims: ev.ActorClaims,
		TenantID:    ev.TenantID,
		DateTime:    ev.DateTime,
		Snapshot:    ev.Snapshot,
		Changes:     auditChangesOf(ev.Changes),
	}
	if len(ev.Children) > 0 {
		r.Children = make(map[string][]appqueries.AuditChildResult, len(ev.Children))
		for typeName, children := range ev.Children {
			entries := make([]appqueries.AuditChildResult, 0, len(children))
			for _, c := range children {
				entries = append(entries, appqueries.AuditChildResult{
					ID:       c.ID,
					Op:       c.Op,
					Snapshot: c.Snapshot,
					Changes:  auditChangesOf(c.Changes),
				})
			}
			r.Children[typeName] = entries
		}
	}
	return r
}

func auditChangesOf(changes []audit.FieldChange) []appqueries.AuditFieldChangeResult {
	if len(changes) == 0 {
		return nil
	}
	out := make([]appqueries.AuditFieldChangeResult, 0, len(changes))
	for _, c := range changes {
		out = append(out, appqueries.AuditFieldChangeResult{
			Field:      c.Field,
			FieldLabel: c.FieldLabel,
			From:       c.From,
			To:         c.To,
		})
	}
	return out
}
