package handlers

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/queries"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
)

// TestFindUserByDocumentCustomQueryHandler_HappyPath proves the criteria the handler
// hands to ViewReader: Filter[Email]=<value>, Limit=1, IncludeArchived
// flag honored. Returns the single doc the reader returned, untouched —
// projection to FindUserByDocumentCustomResponse is the web layer's job.
func TestFindUserByDocumentCustomQueryHandler_HappyPath(t *testing.T) {
	reader := &fakeViewReader{
		pageToReturn: queries.Page{Items: []map[string]any{
			{"id": "u-1", "name": "Jane", "email": "jane@example.com"},
		}},
	}
	h := &FindUserByDocumentCustomQueryHandler{Reader: reader, View: "users"}

	q := &appqueries.FindUserByDocumentQuery{Document: "jane@example.com"}
	doc, err := h.Handle(testCtx(), q)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if reader.readPageCalled != 1 {
		t.Errorf("expected ReadPage called once, got %d", reader.readPageCalled)
	}
	if reader.gotView != "users" {
		t.Errorf("expected view 'users', got %q", reader.gotView)
	}
	if reader.gotCriteria.Filter["Document"] != "jane@example.com" {
		t.Errorf("expected Filter[Document]=jane@example.com, got %v", reader.gotCriteria.Filter)
	}
	if reader.gotCriteria.Limit != 1 {
		t.Errorf("expected Limit=1, got %d", reader.gotCriteria.Limit)
	}
	if doc["name"] != "Jane" {
		t.Errorf("expected doc Name=Jane, got %v", doc["name"])
	}
}

// TestFindUserByDocumentCustomQueryHandler_NotFound asserts an empty Items slice
// produces a NotFound error so the wire surface lands on 404.
func TestFindUserByDocumentCustomQueryHandler_NotFound(t *testing.T) {
	reader := &fakeViewReader{pageToReturn: queries.Page{Items: []map[string]any{}}}
	h := &FindUserByDocumentCustomQueryHandler{Reader: reader, View: "users"}

	q := &appqueries.FindUserByDocumentQuery{Document: "ghost@example.com"}
	_, err := h.Handle(testCtx(), q)
	if err == nil {
		t.Fatal("expected NotFound error from empty Items")
	}
}

// TestFindUserByDocumentCustomQueryHandler_HonorsIncludeArchived asserts the archived
// flag propagates to the criteria — same contract the canonical surface
// honors via ?archived=true on /users/:id.
func TestFindUserByDocumentCustomQueryHandler_HonorsIncludeArchived(t *testing.T) {
	reader := &fakeViewReader{
		pageToReturn: queries.Page{Items: []map[string]any{
			{"id": "u-1", "name": "Archived Jane", "email": "jane@example.com"},
		}},
	}
	h := &FindUserByDocumentCustomQueryHandler{Reader: reader, View: "users"}

	q := &appqueries.FindUserByDocumentQuery{
		Document:        "jane@example.com",
		IncludeArchived: true,
	}
	if _, err := h.Handle(testCtx(), q); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !reader.gotCriteria.IncludeArchived {
		t.Error("expected IncludeArchived=true to reach the reader")
	}
}
