//go:build qa

package qafixtures

import (
	"context"
	"fmt"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	"github.com/ClaudioSchirmer/omnicore/infra/grpcclient"

	"github.com/ClaudioSchirmer/omnicore-example-users/proto/gen/qafixturesv1"
	"github.com/ClaudioSchirmer/omnicore-example-users/proto/gen/qafixturesv1/qafixturesv1connect"
)

// QAGRPCService is the consumer adapter for the grpcclient RESILIENCE
// fixtures — two upstream declarations on purpose: `self-qa-flaky` carries
// retry+idempotency (breaker off, so the retry budget is observable) and
// `self-qa-boom` carries an aggressive breaker (retry off, so failures feed
// the state machine 1:1). The FlakyEcho fixture counts attempts and
// distinct idempotency keys server-side, making the client-chain e2e
// checks fully deterministic.
type QAGRPCService struct {
	flaky qafixturesv1connect.QAServiceClient
	boom  qafixturesv1connect.QAServiceClient
}

func NewQAGRPCService(c *grpcclient.Client) (*QAGRPCService, error) {
	if c == nil {
		return nil, fmt.Errorf("qafixtures: QAGRPCService requires Deps.GRPCClient")
	}
	flaky, err := grpcclient.For(c, "self-qa-flaky", qafixturesv1connect.NewQAServiceClient)
	if err != nil {
		return nil, fmt.Errorf("qafixtures: QAGRPCService: %w", err)
	}
	boom, err := grpcclient.For(c, "self-qa-boom", qafixturesv1connect.NewQAServiceClient)
	if err != nil {
		return nil, fmt.Errorf("qafixtures: QAGRPCService: %w", err)
	}
	return &QAGRPCService{flaky: flaky, boom: boom}, nil
}

// FlakyEcho drives the retry+idempotency chain against the flaky fixture.
func (s *QAGRPCService) FlakyEcho(ctx context.Context, key string, failTimes int32) (*qafixturesv1.FlakyEchoResponse, error) {
	res, err := s.flaky.FlakyEcho(ctx, connect.NewRequest(&qafixturesv1.FlakyEchoRequest{
		Key:       proto.String(key),
		FailTimes: proto.Int32(failTimes),
	}))
	if err != nil {
		return nil, err
	}
	return res.Msg, nil
}

// Boom drives the breaker chain against the always-down fixture.
func (s *QAGRPCService) Boom(ctx context.Context) error {
	_, err := s.boom.Boom(ctx, connect.NewRequest(&qafixturesv1.BoomRequest{}))
	return err
}
