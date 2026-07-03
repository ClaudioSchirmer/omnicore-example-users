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
