package handlers

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/queries"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/application/queries"
)

// TestFindUsersCustomQueryHandler_HappyPath proves the handler forwards the Criteria
// verbatim to the ViewReader and returns the Page unchanged — the wire
// layer is responsible for the projection step.
func TestFindUsersCustomQueryHandler_HappyPath(t *testing.T) {
	reader := &fakeViewReader{
		pageToReturn: queries.Page{
			Items: []map[string]any{
				{"id": "u-1", "name": "Jane", "email": "jane@example.com"},
				{"id": "u-2", "name": "Bob", "email": "bob@example.com"},
			},
			HasNext:    true,
			NextCursor: "cursor-X",
			Total:      42,
		},
	}
	h := &FindUsersCustomQueryHandler{Reader: reader, View: "users"}

	q := &appqueries.FindUsersCustomQuery{Criteria: queries.ReadCriteria{
		Filter: map[string]any{"name": "Ja"},
		Limit:  10,
	}}
	page, err := h.Handle(testCtx(), q)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if reader.readPageCalled != 1 {
		t.Errorf("expected ReadPage called once, got %d", reader.readPageCalled)
	}
	if reader.gotCriteria.Filter["name"] != "Ja" || reader.gotCriteria.Limit != 10 {
		t.Errorf("criteria not forwarded as expected: %+v", reader.gotCriteria)
	}
	if len(page.Items) != 2 {
		t.Errorf("expected 2 items, got %d", len(page.Items))
	}
	if !page.HasNext || page.NextCursor != "cursor-X" || page.Total != 42 {
		t.Errorf("pagination metadata not preserved: %+v", page)
	}
}

// TestFindUsersCustomQueryHandler_EmptyPage asserts a 0-item Page is a valid result
// (not an error) — a list with no matches is the happy path, just empty.
func TestFindUsersCustomQueryHandler_EmptyPage(t *testing.T) {
	reader := &fakeViewReader{pageToReturn: queries.Page{Items: []map[string]any{}}}
	h := &FindUsersCustomQueryHandler{Reader: reader, View: "users"}

	q := &appqueries.FindUsersCustomQuery{}
	page, err := h.Handle(testCtx(), q)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(page.Items) != 0 {
		t.Errorf("expected empty Items, got %d", len(page.Items))
	}
}

// TestFindUsersCustomQueryHandler_NilFilterIsInitialized proves the handler does not
// panic when the criteria arrives with a nil Filter map — the access
// control seam (in the commented sample) writes into criteria.Filter, so
// the handler must guarantee it is initialized before reaching the seam.
func TestFindUsersCustomQueryHandler_NilFilterIsInitialized(t *testing.T) {
	reader := &fakeViewReader{}
	h := &FindUsersCustomQueryHandler{Reader: reader, View: "users"}

	q := &appqueries.FindUsersCustomQuery{Criteria: queries.ReadCriteria{Filter: nil}}
	if _, err := h.Handle(testCtx(), q); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if reader.gotCriteria.Filter == nil {
		t.Error("expected Filter map to be initialized before reaching ReadPage")
	}
}
