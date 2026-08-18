package handlers

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/queries"

	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
)

// TestFindUsersCustomQueryHandler_HappyPath proves the handler forwards the Criteria
// verbatim to the ViewReader and returns the reader's Page as a typed
// queries.PageOf — one Result per document (filled by the framework from the
// canonical Go-keyed doc, then passed through the Query's FromQueryResult hook),
// with the cursor envelope copied verbatim. The wire layer maps Result →
// Response; the raw document never crosses the boundary.
func TestFindUsersCustomQueryHandler_HappyPath(t *testing.T) {
	reader := &fakeViewReader{
		pageToReturn: queries.Page{
			// Go-keyed documents — what the ViewReader hands the application
			// layer after translating every physical column back through the
			// view's TableSchema.
			Items: []map[string]any{
				{"ID": "u-1", "Name": "Jane", "Email": "jane@example.com"},
				{"ID": "u-2", "Name": "Bob", "Email": "bob@example.com"},
			},
			HasNextPage: true,
			EndCursor:   "cursor-X",
			TotalCount:  42,
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
		t.Fatalf("expected 2 items, got %d", len(page.Items))
	}
	// Typed Results, filled by name from the canonical document.
	if page.Items[0].Name == nil || *page.Items[0].Name != "Jane" {
		t.Errorf("Items[0].Name: want Jane, got %v", page.Items[0].Name)
	}
	if page.Items[1].ID == nil || *page.Items[1].ID != "u-2" {
		t.Errorf("Items[1].ID: want u-2, got %v", page.Items[1].ID)
	}
	if !page.HasNextPage || page.EndCursor != "cursor-X" || page.TotalCount != 42 {
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
