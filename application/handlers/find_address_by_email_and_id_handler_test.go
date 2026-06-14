package handlers

import (
	"errors"
	"testing"

	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	"github.com/ClaudioSchirmer/omnicore/domain"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
)

func TestFindAddressByEmailAndIDQueryHandler_HappyPath(t *testing.T) {
	reader := &fakeViewReader{
		pageToReturn: fwqueries.Page{Items: []map[string]any{
			{
				"id":    "user-1",
				"email": "jane@example.com",
				"addresses": []any{
					map[string]any{"id": "addr-1", "street": "1 Audit Way"},
					map[string]any{"id": "addr-2", "street": "2 Other"},
				},
			},
		}},
	}
	h := &FindAddressByEmailAndIDQueryHandler{Reader: reader, View: "users"}

	got, err := h.Handle(testCtx(),
		&appqueries.FindAddressByEmailAndIDQuery{Email: "jane@example.com", AddressID: "addr-2"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got["street"] != "2 Other" {
		t.Errorf("expected addr-2's payload, got %+v", got)
	}
	if reader.readPageCalled != 1 {
		t.Errorf("expected ReadPage called once, got %d", reader.readPageCalled)
	}
	if reader.gotCriteria.Filter["email"] != "jane@example.com" {
		t.Errorf("expected email filter applied, got %+v", reader.gotCriteria.Filter)
	}
}

func TestFindAddressByEmailAndIDQueryHandler_UserMissing(t *testing.T) {
	reader := &fakeViewReader{pageToReturn: fwqueries.Page{Items: []map[string]any{}}}
	h := &FindAddressByEmailAndIDQueryHandler{Reader: reader, View: "users"}

	_, err := h.Handle(testCtx(),
		&appqueries.FindAddressByEmailAndIDQuery{Email: "ghost@example.com", AddressID: "x"})
	if err == nil {
		t.Fatal("expected RecordNotFound on missing user")
	}
	var carrier domain.NotificationCarrier
	if !errors.As(err, &carrier) {
		t.Fatalf("expected NotificationCarrier, got %T", err)
	}
	if got := carrier.NotificationContexts()[0].Context(); got != "User" {
		t.Errorf("expected User context, got %q", got)
	}
}

func TestFindAddressByEmailAndIDQueryHandler_AddressMissingInDoc(t *testing.T) {
	reader := &fakeViewReader{
		pageToReturn: fwqueries.Page{Items: []map[string]any{{
			"id":    "user-1",
			"email": "jane@example.com",
			"addresses": []any{
				map[string]any{"id": "addr-1", "street": "x"},
			},
		}}},
	}
	h := &FindAddressByEmailAndIDQueryHandler{Reader: reader, View: "users"}

	_, err := h.Handle(testCtx(),
		&appqueries.FindAddressByEmailAndIDQuery{Email: "jane@example.com", AddressID: "missing"})
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
