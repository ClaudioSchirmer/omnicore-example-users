//go:build qa

package qafixtures

import (
	"time"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/notifications"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/domain"
)

// ─── 503 Service Unavailable showcase ───────────────────────────────────────

// UnavailableGadgetQuery drives the 503 showcase: a query whose handler always
// fails with ServiceUnavailableNotification. It carries no input — the point is
// purely to prove the notification's Semantic (SemanticUnavailable) maps to a
// 503 through the same pipeline + RespondFromResult path every other read uses.
type UnavailableGadgetQuery struct{ pipeline.QueryBase }

// UnavailableGadgetHandler always returns a NotificationCarrier error wrapping
// ServiceUnavailableNotification. pipeline.Run catches it via errors.As, renders
// the ContextDTOs, and RespondFromResult maps SemanticUnavailable → 503. The
// wire envelope carries the "ServiceUnavailableNotification" key.
type UnavailableGadgetHandler struct{}

func (h *UnavailableGadgetHandler) Handle(
	_ *configuration.AppContext, _ *UnavailableGadgetQuery,
) (fwresults.None, error) {
	return fwresults.None{}, domain.SingleNotificationError(
		"Gadget", "service", notifications.ServiceUnavailableNotification{},
	)
}

var _ pipeline.Handler[*UnavailableGadgetQuery, fwresults.None] = (*UnavailableGadgetHandler)(nil)

// ─── 504 Gateway Timeout showcase ───────────────────────────────────────────

// SlowGadgetQuery drives the 504 showcase: a query that sleeps for a
// caller-configurable duration while honoring the request context deadline.
// When the sleep outlasts http.requestTimeoutSeconds, the AppContext deadline
// fires, the handler returns ctx.Err() (context.DeadlineExceeded), and
// pipeline.Run maps it to RequestTimeoutNotification → 504.
type SlowGadgetQuery struct {
	pipeline.QueryBase
	Sleep time.Duration
}

// SlowGadgetHandler blocks up to q.Sleep but releases immediately on
// cancellation — the select races the timer against ctx.Done(), so a blown
// request deadline aborts the handler instead of holding the goroutine.
type SlowGadgetHandler struct{}

func (h *SlowGadgetHandler) Handle(
	ctx *configuration.AppContext, q *SlowGadgetQuery,
) (fwresults.None, error) {
	select {
	case <-ctx.Done():
		return fwresults.None{}, ctx.Err()
	case <-time.After(q.Sleep):
		return fwresults.None{}, nil
	}
}

var _ pipeline.Handler[*SlowGadgetQuery, fwresults.None] = (*SlowGadgetHandler)(nil)

// ─── The echoed-value contract ──────────────────────────────────────────────

// The two value-object flavours, neither declaring String(). That is the point:
// a VO is a named type over a base type, and it is exactly the shape whose
// POINTER fmt renders as an address.
type (
	echoRawVO     string // raw VO — type Email string
	echoStrEnumVO string // enum VO, string-backed — what every VO here is
	echoIntEnumVO int    // enum VO, int-backed — the framework allows both
)

// echoStringerVO is the counter-case: a type that renders ITSELF. Its pointer
// must keep that rendering rather than be unwrapped into the bare struct.
type echoStringerVO struct{ raw string }

func (v *echoStringerVO) String() string { return "vo(" + v.raw + ")" }

// EchoValuesQuery drives the notification value-echo showcase.
//
// The rule it stands for is the one every optional field lands on: a value was
// refused, and the caller is told WHICH value. That echo travels through the
// `value` variadic of AddNotification, and until it was fixed a pointer whose
// type does not render itself arrived as a memory ADDRESS — a rule firing
// correctly, reported through a message nobody can act on.
//
// It went unseen for two reasons worth keeping written down. An address is a
// perfectly valid rendering of a pointer, so nothing errored and no assertion
// that merely checked "a value came back" could tell. And the ONE optional field
// this service ever echoed was a *time.Time, which was never affected: time.Time
// has String(), so its pointer satisfies fmt.Stringer. The broken path simply
// did not exist here — which is exactly what this fixture now supplies.
//
// It is a QA fixture rather than a rule on a real aggregate because the failure
// is about the TYPE of what is echoed, not about any one domain invariant. One
// route covers the whole matrix; a nullable column on one fixture would cover a
// single cell of it and imply the rest were safe.
type EchoValuesQuery struct{ pipeline.QueryBase }

// EchoValuesHandler emits ONE message per value flavour, all through the same
// AddNotification the Rules DSL calls. Each field NAMES what it carries, so the
// suite asserts by name and never by position.
type EchoValuesHandler struct{}

func (h *EchoValuesHandler) Handle(
	_ *configuration.AppContext, _ *EchoValuesQuery,
) (fwresults.None, error) {
	i, i64, f, b := 15, int64(-7), 2.5, true
	s := "plain"
	when := time.Date(2026, 8, 15, 10, 30, 0, 0, time.UTC)
	raw, strEnum, intEnum := echoRawVO("ana@corp.com"), echoStrEnumVO("white"), echoIntEnumVO(3)
	stringer := &echoStringerVO{raw: "x"}

	ctx := domain.NewNotificationContext("EchoValues")
	for _, c := range []struct {
		field string
		value any
	}{
		// Scalars a caller sends directly.
		{"valueInt", i},
		{"valueString", s},
		{"valueTime", when},
		{"valueRawVO", raw},
		// The OPTIONAL half — every field a request may omit is a pointer, and
		// this is where the address bug lived.
		{"pointerInt", &i},
		{"pointerInt64", &i64},
		{"pointerFloat", &f},
		{"pointerBool", &b},
		{"pointerString", &s},
		{"pointerTime", &when},
		{"pointerRawVO", &raw},
		{"pointerStrEnumVO", &strEnum},
		{"pointerIntEnumVO", &intEnum},
		// A type that renders itself keeps doing so through its pointer.
		{"pointerStringer", stringer},
		// An absent value is not a value: it renders as the empty string, which
		// omitempty then drops from the wire entirely.
		{"nilPointer", (*int)(nil)},
	} {
		ctx.AddNotification(c.field, domain.SchemaViolationNotification{}, c.value)
	}
	return fwresults.None{}, domain.NewDomainError([]*domain.NotificationContext{ctx})
}

var _ pipeline.Handler[*EchoValuesQuery, fwresults.None] = (*EchoValuesHandler)(nil)
