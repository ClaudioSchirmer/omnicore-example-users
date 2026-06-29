package handlers

import (
	"github.com/ClaudioSchirmer/omnicore/application/audit"
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/translation"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
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
//  3. Returns the slice. The wire layer serializes *AuditEvent's JSON
//     tags directly — no additional projection is needed because the
//     framework's AuditEvent struct already carries the wire-correct
//     shape.
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
) ([]*audit.AuditEvent, error) {
	events, err := h.Reader.FindByAggregate(ctx, q.EntityType, q.AggregateID)
	if err != nil {
		return nil, err
	}
	lang := ctx.Language()
	for _, ev := range events {
		audit.RenderLabels(ev, h.Translator, lang)
	}
	return events, nil
}
