//go:build qa

package qafixtures

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/domain"
)

// ─── Producer side — integration event payload + publish port ───────────────

// GadgetCreatedEvent is the JSON payload marshalled onto the `gadgetCreated`
// integration event. The GadgetID is the string form of the aggregate id (also
// stamped as the row's aggregate_id via WithAggregateID); the four business
// fields mirror the inserted Gadget so a downstream consumer can materialize a
// projection without reading back the source. Wire keys are lowerCamel and MUST
// match GadgetCreatedReceivedRequest (web/qafixtures) so self-consumption
// round-trips.
type GadgetCreatedEvent struct {
	GadgetID string `json:"gadgetId"`
	Code     string `json:"code"`
	Name     string `json:"name"`
	Category string `json:"category"`
	Status   string `json:"status"`
}

// GadgetEventPublisher is the in-TX producer port the insert lifecycle hooks
// call from BeforeCommit. Like GadgetJournal, the TxHandle is a sealed marker
// the adapter (infra/qafixtures) recovers to thread the integration_events row
// into the SAME transaction as the data + outbox + audit writes — so a forced
// rollback (Code == "POISON") reverts the event alongside the gadget row. The
// application layer never pronounces the Dispatch call; the adapter owns it.
type GadgetEventPublisher interface {
	Publish(ctx *configuration.AppContext, tx persistence.TxHandle, id domain.ID, evt GadgetCreatedEvent) error
}

// publisher is the wire-time-injected producer adapter the Auto command's
// BeforeCommit hook calls. Mirrors the journal singleton: the Auto path builds
// the command from the request DTO (ToCommand), which has no injection point,
// so the port lands here as a package singleton set once at boot via
// UsePublisher. The MANUAL path (InsertGadgetCustomHandler) receives its port by
// constructor injection instead.
var publisher GadgetEventPublisher

// UsePublisher injects the producer adapter used by the Auto command hooks.
// Called exactly once by the GadgetFeature at boot, alongside UseJournal.
func UsePublisher(p GadgetEventPublisher) { publisher = p }

// ─── Consumer side — idempotent sink command + handler ──────────────────────

// RecordGadgetEventCommand is the application-layer "record a received
// gadgetCreated event" use case. It is the command the receiver's wire DTO
// (GadgetCreatedReceivedRequest) maps to via ToCommand. The handler writes ONE
// idempotent row to gadget_events_sink keyed by GadgetID, honoring the
// at-least-once delivery contract (a redelivered event is a no-op).
type RecordGadgetEventCommand struct {
	pipeline.CommandBase
	GadgetID string
	Code     string
	Name     string
	Category string
	Status   string
}

// GadgetEventSink is the idempotent sink-write port. The adapter
// (infra/qafixtures) opens its own short single-statement write (no outer TX on
// the receiver path — framework invariant #10) and renders the
// dialect-appropriate upsert-do-nothing so a duplicate delivery is a silent
// no-op.
type GadgetEventSink interface {
	Record(ctx *configuration.AppContext, cmd *RecordGadgetEventCommand) error
}

// RecordGadgetEventHandler is the pipeline.CommandHandler-shaped receiver
// handler — the SAME Handle(ctx, cmd) (Result, error) shape HTTP routes consume,
// which is why the integration Registry can drive it through reflection. The
// sink port arrives by constructor injection (the GadgetFeature wires it in
// MountReceivers).
type RecordGadgetEventHandler struct {
	Sink GadgetEventSink
}

func (h *RecordGadgetEventHandler) Handle(
	ctx *configuration.AppContext, cmd *RecordGadgetEventCommand,
) (fwresults.None, error) {
	if err := h.Sink.Record(ctx, cmd); err != nil {
		return fwresults.None{}, err
	}
	return fwresults.None{}, nil
}

var _ pipeline.CommandHandler[*RecordGadgetEventCommand, fwresults.None] = (*RecordGadgetEventHandler)(nil)
