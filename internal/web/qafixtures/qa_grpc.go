//go:build qa

package qafixtures

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"connectrpc.com/connect"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/domain"
	fwgrpc "github.com/ClaudioSchirmer/omnicore/web/grpc"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/qafixtures"
	"github.com/ClaudioSchirmer/omnicore-example-users/proto/gen/qafixturesv1"
	"github.com/ClaudioSchirmer/omnicore-example-users/proto/gen/qafixturesv1/qafixturesv1connect"
)

// qa_grpc.go — the QA-only gRPC fixture surface. Provoke and ListGadgets
// ride the canonical constructors (they exercise the real dispatch); the
// FlakyEcho/Boom transport fixtures are raw-mounted (MountRaw) because
// their whole purpose is observing the CLIENT chain's wire behavior
// (retry attempts, idempotency headers) — server-side counters make the
// grpcclient e2e checks deterministic.

// ─── Provoke: the full Semantic → code table through a real dispatch ───────

type provokeCommand struct {
	pipeline.CommandWithBodyBase
	Semantic string
}

// provokeDTO is Provoke's Request-DTO seat: the bridge fills it from the
// proto and ToCommand crosses into the application layer, exactly like a
// REST body DTO.
type provokeDTO struct {
	Semantic string `json:"semantic"`
}

func (d provokeDTO) ToCommand() *provokeCommand {
	return &provokeCommand{Semantic: d.Semantic}
}

type provokeHandler struct{}

var provokeSemantics = map[string]domain.NotificationSemantic{
	"validation":         domain.SemanticValidation,
	"schema":             domain.SemanticSchema,
	"not_found":          domain.SemanticNotFound,
	"conflict":           domain.SemanticConflict,
	"state_conflict":     domain.SemanticStateConflict,
	"forbidden":          domain.SemanticForbidden,
	"unauthorized":       domain.SemanticUnauthorized,
	"unavailable":        domain.SemanticUnavailable,
	"method_not_allowed": domain.SemanticMethodNotAllowed,
	"payload_too_large":  domain.SemanticPayloadTooLarge,
	"gateway_timeout":    domain.SemanticGatewayTimeout,
}

func (provokeHandler) Handle(_ *configuration.AppContext, cmd *provokeCommand) (*struct{}, error) {
	if cmd.Semantic == "internal" {
		return nil, errors.New("provoked exception: this text must never reach the wire")
	}
	sem, ok := provokeSemantics[cmd.Semantic]
	if !ok {
		return nil, fmt.Errorf("unknown semantic %q", cmd.Semantic)
	}
	nctx := domain.NewNotificationContext("QA")
	nctx.AddNotificationMessage(domain.NotificationMessage{
		FieldName:    "semantic",
		Notification: domain.RequiredFieldNotification{}.WithSemantic(sem),
	})
	return nil, domain.NewDomainError([]*domain.NotificationContext{nctx})
}

// ─── EchoTypes: the wire-type matrix through the real bridge ───────────────
//
// One command carrying EVERY proto scalar kind, echoed back. The DTO seats
// below are the SAME plain Go shapes a REST body binds — money as int64
// minor units, no gRPC-specific spelling, no `,string` tag: the framework
// reconciles the one place the two JSON dialects disagree (the proto3 JSON
// mapping quotes 64-bit integers; encoding/json does not). SumCents is
// computed by the HANDLER on the bound values, so a green case proves they
// arrived as numbers the domain can do arithmetic on, not as text.

type echoTypesChild struct {
	ChildCents int64  `json:"childCents"`
	ChildLabel string `json:"childLabel"`
}

type echoTypesDTO struct {
	PriceCents       *int64           `json:"priceCents"`
	SignedDelta      *int64           `json:"signedDelta"`
	FixedSigned      *int64           `json:"fixedSigned"`
	HugeCount        *uint64          `json:"hugeCount"`
	FixedUnsigned    *uint64          `json:"fixedUnsigned"`
	Quantity         *int32           `json:"quantity"`
	UnsignedQuantity *uint32          `json:"unsignedQuantity"`
	Weight           *float64         `json:"weight"`
	Ratio            *float32         `json:"ratio"`
	Active           *bool            `json:"active"`
	Label            *string          `json:"label"`
	Payload          []byte           `json:"payload"`
	Flavor           *string          `json:"flavor"`
	OccurredAt       time.Time        `json:"occurredAt"`
	Amounts          []int64          `json:"amounts"`
	Tags             []string         `json:"tags"`
	Child            echoTypesChild   `json:"child"`
	Children         []echoTypesChild `json:"children"`
}

// echoTypesCommand is the application-layer seat: presence already resolved,
// plain Go types, no proto in sight.
type echoTypesCommand struct {
	pipeline.CommandWithBodyBase
	PriceCents       int64
	SignedDelta      int64
	FixedSigned      int64
	HugeCount        uint64
	FixedUnsigned    uint64
	Quantity         int32
	UnsignedQuantity uint32
	Weight           float64
	Ratio            float32
	Active           bool
	Label            string
	LabelPresent     bool
	Payload          []byte
	Flavor           string
	OccurredAt       time.Time
	Amounts          []int64
	Tags             []string
	Child            echoTypesChild
	Children         []echoTypesChild
}

func (d echoTypesDTO) ToCommand() *echoTypesCommand {
	cmd := &echoTypesCommand{
		Payload:      d.Payload,
		OccurredAt:   d.OccurredAt,
		Amounts:      d.Amounts,
		Tags:         d.Tags,
		Child:        d.Child,
		Children:     d.Children,
		LabelPresent: d.Label != nil,
		// An empty enum string is not a member name; UNSPECIFIED is the
		// absent value the wire round-trips.
		Flavor: "FLAVOR_UNSPECIFIED",
	}
	if d.PriceCents != nil {
		cmd.PriceCents = *d.PriceCents
	}
	if d.SignedDelta != nil {
		cmd.SignedDelta = *d.SignedDelta
	}
	if d.FixedSigned != nil {
		cmd.FixedSigned = *d.FixedSigned
	}
	if d.HugeCount != nil {
		cmd.HugeCount = *d.HugeCount
	}
	if d.FixedUnsigned != nil {
		cmd.FixedUnsigned = *d.FixedUnsigned
	}
	if d.Quantity != nil {
		cmd.Quantity = *d.Quantity
	}
	if d.UnsignedQuantity != nil {
		cmd.UnsignedQuantity = *d.UnsignedQuantity
	}
	if d.Weight != nil {
		cmd.Weight = *d.Weight
	}
	if d.Ratio != nil {
		cmd.Ratio = *d.Ratio
	}
	if d.Active != nil {
		cmd.Active = *d.Active
	}
	if d.Label != nil {
		cmd.Label = *d.Label
	}
	if d.Flavor != nil && *d.Flavor != "" {
		cmd.Flavor = *d.Flavor
	}
	return cmd
}

// echoTypesResult is what the handler returns: the bound values plus the
// arithmetic it did ON them.
type echoTypesResult struct {
	Cmd      *echoTypesCommand
	SumCents int64
}

type echoTypesHandler struct{}

func (echoTypesHandler) Handle(_ *configuration.AppContext, cmd *echoTypesCommand) (*echoTypesResult, error) {
	sum := cmd.PriceCents + cmd.Child.ChildCents
	for _, a := range cmd.Amounts {
		sum += a
	}
	for _, c := range cmd.Children {
		sum += c.ChildCents
	}
	return &echoTypesResult{Cmd: cmd, SumCents: sum}, nil
}

// echoTypesResponse is the wire shape of the echo — the response half of the
// same matrix.
type echoTypesResponse struct {
	PriceCents       int64            `json:"priceCents"`
	SignedDelta      int64            `json:"signedDelta"`
	FixedSigned      int64            `json:"fixedSigned"`
	HugeCount        uint64           `json:"hugeCount"`
	FixedUnsigned    uint64           `json:"fixedUnsigned"`
	Quantity         int32            `json:"quantity"`
	UnsignedQuantity uint32           `json:"unsignedQuantity"`
	Weight           float64          `json:"weight"`
	Ratio            float32          `json:"ratio"`
	Active           bool             `json:"active"`
	Label            string           `json:"label"`
	Payload          []byte           `json:"payload"`
	Flavor           string           `json:"flavor"`
	OccurredAt       time.Time        `json:"occurredAt"`
	Amounts          []int64          `json:"amounts"`
	Tags             []string         `json:"tags"`
	Child            echoTypesChild   `json:"child"`
	Children         []echoTypesChild `json:"children"`
	SumCents         int64            `json:"sumCents"`
	LabelPresent     bool             `json:"labelPresent"`
}

func echoTypesResponseFrom(r *echoTypesResult) echoTypesResponse {
	c := r.Cmd
	return echoTypesResponse{
		PriceCents:       c.PriceCents,
		SignedDelta:      c.SignedDelta,
		FixedSigned:      c.FixedSigned,
		HugeCount:        c.HugeCount,
		FixedUnsigned:    c.FixedUnsigned,
		Quantity:         c.Quantity,
		UnsignedQuantity: c.UnsignedQuantity,
		Weight:           c.Weight,
		Ratio:            c.Ratio,
		Active:           c.Active,
		Label:            c.Label,
		Payload:          c.Payload,
		Flavor:           c.Flavor,
		OccurredAt:       c.OccurredAt,
		Amounts:          c.Amounts,
		Tags:             c.Tags,
		Child:            c.Child,
		Children:         c.Children,
		SumCents:         r.SumCents,
		LabelPresent:     c.LabelPresent,
	}
}

// ─── FlakyEcho / Boom: raw transport fixtures for the client chain ─────────

type grpcFlakyEntry struct {
	attempts int32
	keys     map[string]struct{}
}

var (
	grpcFlakyMu    sync.Mutex
	grpcFlakyState = map[string]*grpcFlakyEntry{}
)

func flakyEcho(_ context.Context, req *connect.Request[qafixturesv1.FlakyEchoRequest]) (*connect.Response[qafixturesv1.FlakyEchoResponse], error) {
	grpcFlakyMu.Lock()
	defer grpcFlakyMu.Unlock()
	key := req.Msg.GetKey()
	entry, ok := grpcFlakyState[key]
	if !ok {
		entry = &grpcFlakyEntry{keys: map[string]struct{}{}}
		grpcFlakyState[key] = entry
	}
	entry.attempts++
	if idem := req.Header().Get("X-Idempotency-Key"); idem != "" {
		entry.keys[idem] = struct{}{}
	}
	if entry.attempts <= req.Msg.GetFailTimes() {
		return nil, connect.NewError(connect.CodeUnavailable, errors.New("flaky fixture failing on purpose"))
	}
	return connect.NewResponse(&qafixturesv1.FlakyEchoResponse{
		Attempts:     entry.attempts,
		DistinctKeys: int32(len(entry.keys)),
	}), nil
}

func boom(context.Context, *connect.Request[qafixturesv1.BoomRequest]) (*connect.Response[qafixturesv1.BoomResponse], error) {
	return nil, connect.NewError(connect.CodeUnavailable, errors.New("boom fixture: always down"))
}

// MountQAGRPC registers the fixture surface on the service's gRPC registry.
// ListGadgets rides the SAME REST DTOs (FindGadgetsRequest's `filter:` tags
// are the operator allowlist; FindGadgetsResponse the mask/sort vocabulary
// and the item projection) — the gRPC file adds zero marshalling.
func MountQAGRPC(reg *fwgrpc.Registry, d bootstrap.Deps) {
	reg.Register(fwgrpc.CommandWithBody[qafixturesv1.ProvokeRequest, qafixturesv1.ProvokeResponse](
		qafixturesv1connect.QAServiceProvokeProcedure,
		provokeDTO{},
		func(*struct{}) struct{} { return struct{}{} },
		provokeHandler{}))

	reg.Register(fwgrpc.QueryWithParams[qafixturesv1.ListGadgetsRequest, qafixturesv1.ListGadgetsResponse](
		qafixturesv1connect.QAServiceListGadgetsProcedure,
		FindGadgetsRequest{},
		fwresponses.AutoFromDoc[FindGadgetsResponse],
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery]{
			Reader: d.ViewReader, View: "gadgets",
		}))

	// ListGadgetsBare is the reserved-gate proof on the gRPC surface: the
	// SAME shared request message, but bound to a Request DTO that declares
	// NO reserved control keys — so every control set on the wire rejects
	// as INVALID_ARGUMENT through the canonical gateway (the shared proto
	// cannot narrow per RPC; the DTO decides what THIS endpoint honors).
	reg.Register(fwgrpc.QueryWithParams[qafixturesv1.ListGadgetsRequest, qafixturesv1.ListGadgetsResponse](
		qafixturesv1connect.QAServiceListGadgetsBareProcedure,
		FindGadgetsBareRequest{},
		fwresponses.AutoFromDoc[FindGadgetsResponse],
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery]{
			Reader: d.ViewReader, View: "gadgets",
		}))

	// The RelationalSource twin of the line above: identical DTO seats, handler
	// and messages — only the View name differs. It exists so the gRPC list
	// envelope (PaginationInfo, total included) is proven over a relationally served
	// page, the third surface reading the same queries.Page the REST and GraphQL
	// mirrors read.
	reg.Register(fwgrpc.QueryWithParams[qafixturesv1.ListGadgetsRequest, qafixturesv1.ListGadgetsResponse](
		qafixturesv1connect.QAServiceListGadgetsRelProcedure,
		FindGadgetsRequest{},
		fwresponses.AutoFromDoc[FindGadgetsResponse],
		&handlers.FindByParamsQueryHandler[*appqa.FindGadgetsQuery]{
			Reader: d.ViewReader, View: "gadgets_rel",
		}))

	reg.Register(fwgrpc.CommandWithBody[qafixturesv1.EchoTypesRequest, qafixturesv1.EchoTypesResponse](
		qafixturesv1connect.QAServiceEchoTypesProcedure,
		echoTypesDTO{},
		echoTypesResponseFrom,
		echoTypesHandler{}))

	reg.MountRaw(qafixturesv1connect.QAServiceFlakyEchoProcedure,
		connect.NewUnaryHandler(qafixturesv1connect.QAServiceFlakyEchoProcedure, flakyEcho))
	reg.MountRaw(qafixturesv1connect.QAServiceBoomProcedure,
		connect.NewUnaryHandler(qafixturesv1connect.QAServiceBoomProcedure, boom))
}
