package handlers

import (
	"errors"
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
)

// queryWithUser builds a FindAddressByIDQuery with the user ID set via the
// embedded QueryBaseWithID.SetPathID, matching what HandleQueryByID does
// at runtime.
func queryWithUser(userID, addressID string, includeArchived bool) *appqueries.FindAddressByIDQuery {
	q := &appqueries.FindAddressByIDQuery{AddressID: addressID, IncludeArchived: includeArchived}
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
	if got["Street"] != "2 Other" {
		t.Errorf("expected addr-2's payload, got %+v", got)
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
