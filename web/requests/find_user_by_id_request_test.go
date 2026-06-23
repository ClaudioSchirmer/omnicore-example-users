package requests

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"
)

func TestFindUserByIDRequest_IncludeArchivedNilDefaultsFalse(t *testing.T) {
	r := FindUserByIDRequest{}
	q := r.ToQuery()
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	crit, _ := q.ToCriteria(ctx)
	if crit.IncludeArchived {
		t.Error("expected IncludeArchived=false when IncludeArchived is nil")
	}
}

func TestFindUserByIDRequest_IncludeArchivedTrue(t *testing.T) {
	tr := true
	r := FindUserByIDRequest{IncludeArchived: &tr}
	q := r.ToQuery()
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	crit, _ := q.ToCriteria(ctx)
	if !crit.IncludeArchived {
		t.Error("expected IncludeArchived=true when IncludeArchived=*true")
	}
}

func TestFindUserByIDRequest_IncludeArchivedFalseIsExplicitFalse(t *testing.T) {
	fl := false
	r := FindUserByIDRequest{IncludeArchived: &fl}
	q := r.ToQuery()
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	crit, _ := q.ToCriteria(ctx)
	if crit.IncludeArchived {
		t.Error("expected IncludeArchived=false when IncludeArchived=*false")
	}
}

// readerGoDoc returns a fixture mirroring what the MongoViewReader hands to the
// projector: Go-field-name keys, not physical columns. The composer writes
// physical columns (zip_code, the embed under "addresses") to Mongo; the reader
// translates each leaf back via UserSchema()/AddressSchema() (zip_code →
// ZipCode) and the embed doc field "addresses" → the Go segment "Addresses"
// before AutoFromDoc projects to the wire. So the fixture speaks Go names.
func readerGoDoc() map[string]any {
	label := "home"
	complement := "Apt 12"
	return map[string]any{
		"ID":    "user-1",
		"Name":  "Jane",
		"Email": "jane@example.com",
		"Phone": "14155552671",
		"Addresses": []any{
			map[string]any{
				"ID":           "addr-1",
				"Label":        label,
				"Street":       "1 Infinite Loop",
				"Number":       "1",
				"Complement":   complement,
				"Neighborhood": "Mariani",
				"City":         "Cupertino",
				"State":        "CA",
				"ZipCode":      "95014", // ← Go field name after reader translation
				"Country":      "US",
			},
		},
	}
}

func TestFindUserByIDResponse_AutoFromDoc_AllRootFieldsPopulated(t *testing.T) {
	got := fwresponses.AutoFromDoc[FindUserByIDResponse](readerGoDoc())
	if got.ID != "user-1" {
		t.Errorf("ID: want user-1, got %q", got.ID)
	}
	if got.Name != "Jane" {
		t.Errorf("Name: want Jane, got %q", got.Name)
	}
	if got.Email != "jane@example.com" {
		t.Errorf("Email: want jane@example.com, got %q", got.Email)
	}
	if got.Phone == nil || *got.Phone != "14155552671" {
		t.Errorf("Phone: want 14155552671, got %v", got.Phone)
	}
}

func TestFindUserByIDResponse_AutoFromDoc_AllAddressFieldsPopulated(t *testing.T) {
	got := fwresponses.AutoFromDoc[FindUserByIDResponse](readerGoDoc())
	if len(got.Addresses) != 1 {
		t.Fatalf("expected 1 address, got %d", len(got.Addresses))
	}
	a := got.Addresses[0]
	if a.ID != "addr-1" {
		t.Errorf("Addr.ID: want addr-1, got %q", a.ID)
	}
	if a.Label == nil || *a.Label != "home" {
		t.Errorf("Addr.Label: want home, got %v", a.Label)
	}
	if a.Street != "1 Infinite Loop" {
		t.Errorf("Addr.Street: want 1 Infinite Loop, got %q", a.Street)
	}
	if a.Number != "1" {
		t.Errorf("Addr.Number: want 1, got %q", a.Number)
	}
	if a.Complement == nil || *a.Complement != "Apt 12" {
		t.Errorf("Addr.Complement: want Apt 12, got %v", a.Complement)
	}
	if a.Neighborhood != "Mariani" {
		t.Errorf("Addr.Neighborhood: want Mariani, got %q", a.Neighborhood)
	}
	if a.City != "Cupertino" {
		t.Errorf("Addr.City: want Cupertino, got %q", a.City)
	}
	if a.State != "CA" {
		t.Errorf("Addr.State: want CA, got %q", a.State)
	}
	if a.ZipCode != "95014" {
		t.Errorf("Addr.ZipCode: want 95014, got %q", a.ZipCode)
	}
	if a.Country != "US" {
		t.Errorf("Addr.Country: want US, got %q", a.Country)
	}
}

func TestFindUserByIDResponse_AutoFromDoc_FallsBackToUnderscoreID(t *testing.T) {
	doc := map[string]any{
		"_id":   "user-2",
		"Name":  "Bob",
		"Email": "bob@example.com",
	}
	got := fwresponses.AutoFromDoc[FindUserByIDResponse](doc)
	if got.ID != "user-2" {
		t.Errorf("expected ID from _id fallback, got %q", got.ID)
	}
}

func TestFindUserByIDResponse_AutoFromDoc_NilAddressesBecomeEmptySlice(t *testing.T) {
	doc := map[string]any{
		"ID":    "user-3",
		"Name":  "Carol",
		"Email": "carol@example.com",
	}
	got := fwresponses.AutoFromDoc[FindUserByIDResponse](doc)
	if got.Addresses == nil {
		t.Error("expected non-nil Addresses slice for missing addresses key")
	}
	if len(got.Addresses) != 0 {
		t.Errorf("expected empty Addresses, got %d", len(got.Addresses))
	}
}

func TestFindUserByIDResponse_AutoFromDoc_OptionalsOmittedWhenAbsent(t *testing.T) {
	doc := map[string]any{
		"ID":    "user-4",
		"Name":  "Dave",
		"Email": "dave@example.com",
	}
	got := fwresponses.AutoFromDoc[FindUserByIDResponse](doc)
	if got.Phone != nil {
		t.Errorf("expected nil Phone when absent, got %v", got.Phone)
	}
}
