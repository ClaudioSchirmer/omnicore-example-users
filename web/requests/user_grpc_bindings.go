package requests

import (
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	fwgrpc "github.com/ClaudioSchirmer/omnicore/web/grpc"

	"github.com/ClaudioSchirmer/omnicore-example-users/application/commands"
	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
	"github.com/ClaudioSchirmer/omnicore-example-users/gen/usersv1"
)

// user_grpc_bindings.go is the gRPC wire boundary of the User aggregate —
// the proto sibling of the REST Request/Response DTO files: one binding
// type per RPC, co-locating the wire→command and result→wire halves, so
// web/user_grpc.go stays a declarative mount list exactly like
// user_routes.go. The generated pb messages are the wire DTOs; these
// bindings are the ToCommand/FromResult seats the REST DTOs already own —
// CreateUserPB delegates to the SAME InsertUserRequest.ToCommand, so both
// wires share one boundary semantics.

// ─── CreateUser ─────────────────────────────────────────────────────────────

type CreateUserPB struct{}

func (CreateUserPB) ToCommand(pb *usersv1.CreateUserRequest) (*commands.InsertUserCommand, error) {
	req := InsertUserRequest{
		Name:     pb.GetName(),
		Email:    pb.GetEmail(),
		Document: pb.GetDocument(),
		UserName: pb.GetUserName(),
	}
	// Presence-aware optionals: only a field SENT on the wire lands on the
	// request, mirroring the JSON body's absent-vs-set distinction.
	if pb.Phone != nil {
		v := pb.GetPhone()
		req.Phone = &v
	}
	if pb.EmailNotification != nil {
		v := pb.GetEmailNotification()
		req.EmailNotification = &v
	}
	if pb.SmsNotification != nil {
		v := pb.GetSmsNotification()
		req.SmsNotification = &v
	}
	return req.ToCommand(), nil
}

func (CreateUserPB) FromResult(r commands.InsertUserResult) *usersv1.CreateUserResponse {
	resp := &usersv1.CreateUserResponse{
		Id:       r.ID.Value(),
		Name:     r.Name,
		Email:    r.Email,
		Document: r.Document,
		UserName: r.UserName,
	}
	if r.Phone != nil {
		v := *r.Phone
		resp.Phone = &v
	}
	return resp
}

// ─── UpdateUser ─────────────────────────────────────────────────────────────

type UpdateUserPB struct{}

// ToCommand delegates to the SAME UpdateUserRequest.ToCommand the REST PUT
// uses; the wrapper injects SetPathID(GetId(pb)) afterwards (the
// CommandWithBodyID seam). The address collection replaces atomically,
// exactly like the REST body.
func (UpdateUserPB) ToCommand(pb *usersv1.UpdateUserRequest) (*commands.UpdateUserCommand, error) {
	req := UpdateUserRequest{
		Name:     pb.GetName(),
		Email:    pb.GetEmail(),
		UserName: pb.GetUserName(),
	}
	if pb.Phone != nil {
		v := pb.GetPhone()
		req.Phone = &v
	}
	if pb.EmailNotification != nil {
		v := pb.GetEmailNotification()
		req.EmailNotification = &v
	}
	if pb.SmsNotification != nil {
		v := pb.GetSmsNotification()
		req.SmsNotification = &v
	}
	req.Addresses = make([]AddressRequest, 0, len(pb.GetAddresses()))
	for _, a := range pb.GetAddresses() {
		addr := AddressRequest{
			Street:       a.GetStreet(),
			Number:       a.GetNumber(),
			Neighborhood: a.GetNeighborhood(),
			City:         a.GetCity(),
			State:        a.GetState(),
			ZipCode:      a.GetZipCode(),
		}
		if a.Label != nil {
			v := a.GetLabel()
			addr.Label = &v
		}
		if a.Complement != nil {
			v := a.GetComplement()
			addr.Complement = &v
		}
		req.Addresses = append(req.Addresses, addr)
	}
	return req.ToCommand(), nil
}

func (UpdateUserPB) FromResult(r commands.UpdateUserResult) *usersv1.UpdateUserResponse {
	resp := &usersv1.UpdateUserResponse{
		Id:       r.ID.Value(),
		Name:     r.Name,
		Email:    r.Email,
		UserName: r.UserName,
	}
	if r.Phone != nil {
		v := *r.Phone
		resp.Phone = &v
	}
	return resp
}

// ─── ListUsers ──────────────────────────────────────────────────────────────

type ListUsersPB struct{}

// ToQuery builds the INPUT criteria from the shared omnicore.v1 components
// via the framework converter — the same operator semantics as the REST
// query string (one emitter). Filter keys are Go field paths; the query
// type's ToCriteria(ctx) still applies its identity overlays (e.g. the
// users:admin Phone restriction) on top, exactly like every surface.
// userWireFields is the view's wire vocabulary — proto field name →
// Go field path; the allowlist read_mask and sort resolve against.
var userWireFields = map[string]string{
	"id":        "ID",
	"name":      "Name",
	"email":     "Email",
	"document":  "Document",
	"user_name": "UserName",
	"phone":     "Phone",
}

func (ListUsersPB) ToQuery(pb *usersv1.ListUsersRequest) (*appqueries.FindUserByParamsQuery, error) {
	crit, err := fwgrpc.NewCriteria().
		Fields(userWireFields).
		Page(pb.GetPage()).
		Sort(pb.GetSort()...).
		ReadMask(pb.GetReadMask()).
		String("UserName", pb.GetFilters().GetUserName()).
		String("Name", pb.GetFilters().GetName()).
		Build()
	if err != nil {
		return nil, err
	}
	return &appqueries.FindUserByParamsQuery{Criteria: crit}, nil
}

func (ListUsersPB) FromPage(p fwqueries.Page) *usersv1.ListUsersResponse {
	resp := &usersv1.ListUsersResponse{Total: p.Total, NextCursor: p.NextCursor, PrevCursor: p.PrevCursor}
	for _, doc := range p.Items {
		resp.Items = append(resp.Items, &usersv1.User{
			Id:       docString(doc, "ID"),
			Name:     docString(doc, "Name"),
			Email:    docString(doc, "Email"),
			Document: docString(doc, "Document"),
			UserName: docString(doc, "UserName"),
		})
	}
	return resp
}

// ─── GetUser ────────────────────────────────────────────────────────────────

type GetUserPB struct{}

func (GetUserPB) ToQuery(pb *usersv1.GetUserRequest) (*appqueries.FindUserByIDQuery, error) {
	return &appqueries.FindUserByIDQuery{IncludeArchived: pb.GetIncludeArchived()}, nil
}

func (GetUserPB) FromDoc(doc map[string]any) *usersv1.GetUserResponse {
	return &usersv1.GetUserResponse{
		Id:       docString(doc, "ID"),
		Name:     docString(doc, "Name"),
		Email:    docString(doc, "Email"),
		Document: docString(doc, "Document"),
		UserName: docString(doc, "UserName"),
	}
}

// ─── ArchiveUser ────────────────────────────────────────────────────────────

type ArchiveUserPB struct{}

func (ArchiveUserPB) FromResult(fwresults.None) *usersv1.ArchiveUserResponse {
	return &usersv1.ArchiveUserResponse{}
}

// docString reads a Go-field-keyed view document value as a string; absent
// or non-string (e.g. projected away by read_mask / Restrict) renders empty,
// the same "absent" the JSON list expresses with omitempty.
func docString(doc map[string]any, key string) string {
	if v, ok := doc[key].(string); ok {
		return v
	}
	return ""
}
