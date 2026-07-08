//go:build qa

package qafixtures

import (
	"context"
	"fmt"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	"github.com/ClaudioSchirmer/omnicore/infra/grpcclient"
	omnicorepb "github.com/ClaudioSchirmer/omnicore/web/grpc/pb"

	"github.com/ClaudioSchirmer/omnicore-example-users/proto/gen/usersv1"
	"github.com/ClaudioSchirmer/omnicore-example-users/proto/gen/usersv1/usersv1connect"
)

// UsersGRPCService is the consumer adapter for the grpcclient showcase —
// the gRPC sibling of EchoService: web routes never import the outbound
// client; they call THIS adapter, which owns the generated Connect client
// built through Deps.GRPCClient (`grpcClient.services.self-users`, the
// loopback to the service's own gRPC listener). Every call runs the full
// client chain: correlation, idempotency key, retry, breaker, per-service
// deadline.
type UsersGRPCService struct {
	users usersv1connect.UsersServiceClient
}

// NewUsersGRPCService resolves the generated client once at composition
// time. A nil toolbox (yaml block absent) or an undeclared service returns
// an error the feature surfaces at mount time.
func NewUsersGRPCService(c *grpcclient.Client) (*UsersGRPCService, error) {
	if c == nil {
		return nil, fmt.Errorf("qafixtures: UsersGRPCService requires Deps.GRPCClient (yaml grpcClient: block absent)")
	}
	users, err := grpcclient.For(c, "self-users", usersv1connect.NewUsersServiceClient)
	if err != nil {
		return nil, fmt.Errorf("qafixtures: UsersGRPCService: %w", err)
	}
	return &UsersGRPCService{users: users}, nil
}

// GetUser fetches one user by id over the gRPC plane. ctx must be the
// request's AppContext (the client chain reads correlation/bearer from it).
func (s *UsersGRPCService) GetUser(ctx context.Context, id string, includeArchived bool) (*usersv1.GetUserResponse, error) {
	res, err := s.users.GetUser(ctx, connect.NewRequest(&usersv1.GetUserRequest{
		Id:              proto.String(id),
		IncludeArchived: includeArchived,
	}))
	if err != nil {
		return nil, err
	}
	return res.Msg, nil
}

// ListUsersByUserName lists users filtered by userName equality (empty =
// unfiltered), composing the shared omnicore.v1 typed criteria.
func (s *UsersGRPCService) ListUsersByUserName(ctx context.Context, userName string) (*usersv1.ListUsersResponse, error) {
	req := &usersv1.ListUsersRequest{}
	if userName != "" {
		req.Filters = &usersv1.UserFilters{UserName: &omnicorepb.StringFilter{
			Conditions: []*omnicorepb.StringCondition{{
				Op: omnicorepb.StringOp_STRING_OP_EQ, Values: []string{userName},
			}},
		}}
	}
	res, err := s.users.ListUsers(ctx, connect.NewRequest(req))
	if err != nil {
		return nil, err
	}
	return res.Msg, nil
}
