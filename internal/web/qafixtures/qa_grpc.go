//go:build qa

package qafixtures

import (
	"context"
	"errors"
	"fmt"
	"sync"

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

	reg.MountRaw(qafixturesv1connect.QAServiceFlakyEchoProcedure,
		connect.NewUnaryHandler(qafixturesv1connect.QAServiceFlakyEchoProcedure, flakyEcho))
	reg.MountRaw(qafixturesv1connect.QAServiceBoomProcedure,
		connect.NewUnaryHandler(qafixturesv1connect.QAServiceBoomProcedure, boom))
}
