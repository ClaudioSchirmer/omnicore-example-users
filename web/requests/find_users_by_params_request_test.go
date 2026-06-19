package requests

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"
)

func TestFindUsersByParamsRequest_ToQueryReturnsCriteria(t *testing.T) {
	r := FindUsersByParamsRequest{}
	crit := fwqueries.ReadCriteria{
		Filter: map[string]any{"name": "Jane"},
		Limit:  10,
	}

	q := r.ToQuery(crit)
	if q == nil {
		t.Fatal("expected non-nil Query")
	}
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	got := q.ToCriteria(ctx)
	if got.Filter["name"] != "Jane" {
		t.Errorf("expected filter[name]=Jane, got %v", got.Filter["name"])
	}
	if got.Limit != 10 {
		t.Errorf("expected Limit=10, got %d", got.Limit)
	}
}

func TestFindUsersByParamsRequest_EmptyCriteriaRoundtrip(t *testing.T) {
	r := FindUsersByParamsRequest{}

	q := r.ToQuery(fwqueries.ReadCriteria{Filter: map[string]any{}})
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	got := q.ToCriteria(ctx)
	if got.Filter == nil {
		t.Error("expected non-nil Filter map even when empty")
	}
	if len(got.Filter) != 0 {
		t.Errorf("expected empty Filter, got %v", got.Filter)
	}
}

// readerGoDocList returns a list-shaped fixture matching what
// MongoViewReader.ReadPage hands the projector: each doc is Go-keyed (the
// reader translated the physical columns back via UserSchema()/AddressSchema()
// and the embed doc field "addresses" → the Go segment "Addresses").
func readerGoDocList() map[string]any {
	return map[string]any{
		"ID":    "user-1",
		"Name":  "Jane",
		"Email": "jane@example.com",
		"Phone": "14155552671",
		"Addresses": []any{
			map[string]any{
				"ID":           "addr-1",
				"Street":       "1 Infinite Loop",
				"Number":       "1",
				"Neighborhood": "Mariani",
				"City":         "Cupertino",
				"State":        "CA",
				"ZipCode":      "95014",
				"Country":      "US",
			},
		},
	}
}

// strDeref returns the dereferenced value of p, or "" when p is nil. Used
// by the test assertions to compare the *string-typed Response fields
// without repeating the nil guard in every check.
func strDeref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func TestFindUsersByParamsResponse_AutoFromDoc_AllRootFieldsPopulated(t *testing.T) {
	got := fwresponses.AutoFromDoc[FindUsersByParamsResponse](readerGoDocList())
	if strDeref(got.ID) != "user-1" {
		t.Errorf("ID: want user-1, got %q", strDeref(got.ID))
	}
	if strDeref(got.Name) != "Jane" {
		t.Errorf("Name: want Jane, got %q", strDeref(got.Name))
	}
	if strDeref(got.Email) != "jane@example.com" {
		t.Errorf("Email: want jane@example.com, got %q", strDeref(got.Email))
	}
	if strDeref(got.Phone) != "14155552671" {
		t.Errorf("Phone: want 14155552671, got %q", strDeref(got.Phone))
	}
}

func TestFindUsersByParamsResponse_AutoFromDoc_AllAddressFieldsPopulated(t *testing.T) {
	got := fwresponses.AutoFromDoc[FindUsersByParamsResponse](readerGoDocList())
	if len(got.Addresses) != 1 {
		t.Fatalf("expected 1 address, got %d", len(got.Addresses))
	}
	a := got.Addresses[0]
	if strDeref(a.ID) != "addr-1" {
		t.Errorf("Addr.ID: want addr-1, got %q", strDeref(a.ID))
	}
	if strDeref(a.Street) != "1 Infinite Loop" {
		t.Errorf("Addr.Street: want 1 Infinite Loop, got %q", strDeref(a.Street))
	}
	if strDeref(a.Number) != "1" {
		t.Errorf("Addr.Number: want 1, got %q", strDeref(a.Number))
	}
	if strDeref(a.Neighborhood) != "Mariani" {
		t.Errorf("Addr.Neighborhood: want Mariani, got %q", strDeref(a.Neighborhood))
	}
	if strDeref(a.City) != "Cupertino" {
		t.Errorf("Addr.City: want Cupertino, got %q", strDeref(a.City))
	}
	if strDeref(a.State) != "CA" {
		t.Errorf("Addr.State: want CA, got %q", strDeref(a.State))
	}
	if strDeref(a.ZipCode) != "95014" {
		t.Errorf("Addr.ZipCode: want 95014, got %q", strDeref(a.ZipCode))
	}
	if strDeref(a.Country) != "US" {
		t.Errorf("Addr.Country: want US, got %q", strDeref(a.Country))
	}
}

func TestFindUsersByParamsResponse_AutoFromDoc_FallsBackToUnderscoreID(t *testing.T) {
	doc := map[string]any{"_id": "user-2", "Name": "Bob", "Email": "bob@example.com"}
	got := fwresponses.AutoFromDoc[FindUsersByParamsResponse](doc)
	if strDeref(got.ID) != "user-2" {
		t.Errorf("expected ID from _id fallback, got %q", strDeref(got.ID))
	}
}

func TestFindUsersByParamsResponse_AutoFromDoc_NilAddressesBecomeEmptySlice(t *testing.T) {
	got := fwresponses.AutoFromDoc[FindUsersByParamsResponse](map[string]any{"ID": "x"})
	if got.Addresses == nil {
		t.Error("expected non-nil Addresses slice (normalizeSlices invariant — even though omitempty will elide it at the JSON wire layer)")
	}
}
