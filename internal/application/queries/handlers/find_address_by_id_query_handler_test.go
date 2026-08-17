package handlers

import (
	"errors"
	"testing"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/domain"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/vos"
)

// queryWithUser builds a FindAddressByIDQuery with the user ID set via the
// embedded QueryByIDBase.SetPathID, matching what QueryByID does
// at runtime.
func queryWithUser(userID, addressID string, includeArchived bool) *appqueries.FindAddressByIDQuery {
	q := &appqueries.FindAddressByIDQuery{
		AddressID: addressID,
		Criteria:  fwqueries.ReadCriteria{IncludeArchived: includeArchived},
	}
	q.SetPathID(userID)
	return q
}

func TestFindAddressByIDQueryHandler_HappyPath(t *testing.T) {
	reader := &fakeViewReader{
		docToReturn: map[string]any{
			"ID":   "user-1",
			"Name": "Jane",
			"Addresses": []any{
				map[string]any{"ID": "addr-1", "Street": "1 Audit Way"},
				map[string]any{"ID": "addr-2", "Street": "2 Other"},
			},
		},
		docFound: true,
	}
	h := &FindAddressByIDQueryHandler{Reader: reader, View: "users"}

	got, err := h.Handle(testCtx(),
		queryWithUser("user-1", "addr-2", false))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// The handler returns the TYPED Result — the raw document never leaves
	// the application layer, so the assertion is a field access, not a map
	// lookup.
	if got.Street != "2 Other" {
		t.Errorf("expected addr-2's payload, got %+v", got)
	}
	if got.ID != "addr-2" {
		t.Errorf("expected the picked address's ID, got %q", got.ID)
	}
	if reader.readByIDCalled != 1 {
		t.Errorf("expected ReadByID called once, got %d", reader.readByIDCalled)
	}
	if reader.gotID != "user-1" {
		t.Errorf("expected ReadByID(user-1), got %q", reader.gotID)
	}
}

func TestFindAddressByIDQueryHandler_UserNotFound(t *testing.T) {
	reader := &fakeViewReader{docFound: false}
	h := &FindAddressByIDQueryHandler{Reader: reader, View: "users"}

	_, err := h.Handle(testCtx(),
		queryWithUser("ghost", "any", false))
	if err == nil {
		t.Fatal("expected RecordNotFound error on missing user")
	}
	var carrier domain.NotificationCarrier
	if !errors.As(err, &carrier) {
		t.Fatalf("expected NotificationCarrier, got %T: %v", err, err)
	}
	ctxs := carrier.NotificationContexts()
	if len(ctxs) == 0 || ctxs[0].Context() != "User" {
		t.Errorf("expected User context on not-found, got %+v", ctxs)
	}
}

func TestFindAddressByIDQueryHandler_AddressNotFoundInDoc(t *testing.T) {
	reader := &fakeViewReader{
		docToReturn: map[string]any{
			"ID": "user-1",
			"Addresses": []any{
				map[string]any{"ID": "addr-1", "Street": "x"},
			},
		},
		docFound: true,
	}
	h := &FindAddressByIDQueryHandler{Reader: reader, View: "users"}

	_, err := h.Handle(testCtx(),
		queryWithUser("user-1", "missing", false))
	if err == nil {
		t.Fatal("expected RecordNotFound on missing address ID")
	}
	var carrier domain.NotificationCarrier
	if !errors.As(err, &carrier) {
		t.Fatalf("expected NotificationCarrier, got %T", err)
	}
	if got := carrier.NotificationContexts()[0].Context(); got != "Address" {
		t.Errorf("expected Address context, got %q", got)
	}
}

func TestFindAddressByIDQueryHandler_NoAddressesArray(t *testing.T) {
	reader := &fakeViewReader{
		docToReturn: map[string]any{"ID": "user-1"},
		docFound:    true,
	}
	h := &FindAddressByIDQueryHandler{Reader: reader, View: "users"}

	_, err := h.Handle(testCtx(),
		queryWithUser("user-1", "any", false))
	if err == nil {
		t.Fatal("expected RecordNotFound when user doc carries no addresses[]")
	}
}

// TestFindAddressByIDQueryHandler_OutOfSetEnumConvergesToUnknown locks the
// read-side convergence contract the remodel moved into the APPLICATION layer:
// the framework's doc→Result fill maps an enum value-object field carrying a
// value outside its declared set to the Unknown sentinel before the Result
// leaves the handler. Because the convergence happens here — not on a wire
// projector — every surface (REST, gRPC, GraphQL, CSV/XLSX) inherits it.
func TestFindAddressByIDQueryHandler_OutOfSetEnumConvergesToUnknown(t *testing.T) {
	reader := &fakeViewReader{
		docToReturn: map[string]any{
			"ID": "user-1",
			"Addresses": []any{
				map[string]any{"ID": "addr-1", "Street": "1 Audit Way", "AddressType": "martian"},
				map[string]any{"ID": "addr-2", "Street": "2 Other", "AddressType": "billing"},
			},
		},
		docFound: true,
	}
	h := &FindAddressByIDQueryHandler{Reader: reader, View: "users"}

	stale, err := h.Handle(testCtx(), queryWithUser("user-1", "addr-1", false))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if stale.AddressType != vos.AddressTypeUnknown {
		t.Errorf("out-of-set AddressType must converge to Unknown, got %q", stale.AddressType)
	}

	member, err := h.Handle(testCtx(), queryWithUser("user-1", "addr-2", false))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if member.AddressType != vos.AddressTypeBilling {
		t.Errorf("a declared member must survive the fill, got %q", member.AddressType)
	}
}
