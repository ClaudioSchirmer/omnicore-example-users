package requests

import (
	"encoding/json"
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
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
	got, _ := q.ToCriteria(ctx)
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
	got, _ := q.ToCriteria(ctx)
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

// responseFromDocList runs the FULL read path the remodel installed: the
// framework fills the application-layer Result from the reader's Go-keyed
// document (fwqueries.ResultFromDoc — the step the query handler performs),
// then the Response's FromResult maps that Result onto the wire shape. The
// raw document never reaches the web layer any more, so a doc→wire assertion
// has to walk both hops.
func responseFromDocList(doc map[string]any) FindUsersByParamsResponse {
	result := fwqueries.ResultFromDoc[queries.FindUsersByParamsResult](doc)
	return FindUsersByParamsResponse{}.FromResult(result)
}

func TestFindUsersByParamsResponse_FromResult_AllRootFieldsPopulated(t *testing.T) {
	got := responseFromDocList(readerGoDocList())
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

func TestFindUsersByParamsResponse_FromResult_AllAddressFieldsPopulated(t *testing.T) {
	got := responseFromDocList(readerGoDocList())
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

func TestFindUsersByParamsResponse_FromResult_FallsBackToUnderscoreID(t *testing.T) {
	doc := map[string]any{"_id": "user-2", "Name": "Bob", "Email": "bob@example.com"}
	got := responseFromDocList(doc)
	if strDeref(got.ID) != "user-2" {
		t.Errorf("expected ID from _id fallback, got %q", strDeref(got.ID))
	}
}

func TestFindUsersByParamsResponse_FromResult_NilAddressesBecomeEmptySlice(t *testing.T) {
	got := responseFromDocList(map[string]any{"ID": "x"})
	if got.Addresses == nil {
		t.Error("expected non-nil Addresses slice (the nil-slice normalization invariant — even though omitempty will elide it at the JSON wire layer)")
	}
}

// TestFindUsersByParamsResponse_FromResult_RenamesOntoWireNames locks the seat
// FromResult now owns: the Result is application-pure (Go field names, NO
// tags) and the Response's json tags are the ONLY place the wire vocabulary
// is declared. Marshalling the mapped Response must therefore emit the json
// names — never the Result's Go names — at the root AND inside the nested
// address, and a Result field the Response does not declare must reach no wire.
func TestFindUsersByParamsResponse_FromResult_RenamesOntoWireNames(t *testing.T) {
	id, name, userName := "user-1", "Jane", "jane"
	profile, freq := 1, 2
	zip, addrType := "95014", "residential"
	result := queries.FindUsersByParamsResult{
		ID:                    &id,
		Name:                  &name,
		UserName:              &userName,
		UserProfile:           &profile,
		NotificationFrequency: &freq,
		Addresses: []queries.FindUsersByParamsAddressResult{
			{ZipCode: &zip, AddressType: &addrType},
		},
	}

	raw, err := json.Marshal(FindUsersByParamsResponse{}.FromResult(result))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var wire map[string]any
	if err := json.Unmarshal(raw, &wire); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	for goName, wireName := range map[string]string{
		"UserName":              "userName",
		"UserProfile":           "userProfile",
		"NotificationFrequency": "notificationFrequency",
	} {
		if _, ok := wire[goName]; ok {
			t.Errorf("the Result's Go name %q must not reach the wire", goName)
		}
		if _, ok := wire[wireName]; !ok {
			t.Errorf("expected wire key %q, got %v", wireName, wire)
		}
	}
	if wire["name"] != "Jane" || wire["id"] != "user-1" {
		t.Errorf("root values not carried under their json names: %v", wire)
	}

	addresses, ok := wire["addresses"].([]any)
	if !ok || len(addresses) != 1 {
		t.Fatalf("expected one address on the wire, got %v", wire["addresses"])
	}
	addr, _ := addresses[0].(map[string]any)
	if _, hasGo := addr["ZipCode"]; hasGo {
		t.Error("the nested Result's Go name ZipCode must not reach the wire")
	}
	if addr["zipCode"] != "95014" || addr["addressType"] != "residential" {
		t.Errorf("nested renaming did not apply: %v", addr)
	}
}

// TestFindUsersByParamsResponse_FromResult_SparseFieldsStayAbsent locks the
// `?fields=` contract end to end: a column Mongo stripped arrives absent on
// the Result (nil pointer), stays nil through FromResult and is elided by
// omitempty — it must never render as a zero value.
func TestFindUsersByParamsResponse_FromResult_SparseFieldsStayAbsent(t *testing.T) {
	got := responseFromDocList(map[string]any{"ID": "user-9", "Name": "Jane"})
	if got.Email != nil {
		t.Errorf("expected nil Email for a projected-out column, got %v", got.Email)
	}

	raw, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var wire map[string]any
	if err := json.Unmarshal(raw, &wire); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if _, ok := wire["email"]; ok {
		t.Errorf("a stripped column must be omitted, not rendered as \"\": %v", wire)
	}
	if wire["name"] != "Jane" {
		t.Errorf("the projected columns must still render: %v", wire)
	}
}
