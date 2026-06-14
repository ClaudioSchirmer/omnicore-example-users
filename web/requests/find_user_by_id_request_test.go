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
	if q.ToCriteria(ctx).IncludeArchived {
		t.Error("expected IncludeArchived=false when IncludeArchived is nil")
	}
}

func TestFindUserByIDRequest_IncludeArchivedTrue(t *testing.T) {
	tr := true
	r := FindUserByIDRequest{IncludeArchived: &tr}
	q := r.ToQuery()
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	if !q.ToCriteria(ctx).IncludeArchived {
		t.Error("expected IncludeArchived=true when IncludeArchived=*true")
	}
}

func TestFindUserByIDRequest_IncludeArchivedFalseIsExplicitFalse(t *testing.T) {
	fl := false
	r := FindUserByIDRequest{IncludeArchived: &fl}
	q := r.ToQuery()
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	if q.ToCriteria(ctx).IncludeArchived {
		t.Error("expected IncludeArchived=false when IncludeArchived=*false")
	}
}

// realComposerDoc returns a fixture mirroring what the framework's Composer
// actually writes to Mongo: snake_case keys exactly matching the Postgres
// column names (zip_code, not zipCode). The view: tag on ZipCode is what
// bridges that gap on the wire.
func realComposerDoc() map[string]any {
	label := "home"
	complement := "Apt 12"
	return map[string]any{
		"id":         "user-1",
		"name":       "Jane",
		"email":      "jane@example.com",
		"phone":      "14155552671",
		"deleted_at": nil,
		"addresses": []any{
			map[string]any{
				"id":           "addr-1",
				"label":        label,
				"street":       "1 Infinite Loop",
				"number":       "1",
				"complement":   complement,
				"neighborhood": "Mariani",
				"city":         "Cupertino",
				"state":        "CA",
				"zip_code":     "95014", // ← snake_case as the composer writes it
				"country":      "US",
				"deleted_at":   nil,
			},
		},
	}
}

func TestFindUserByIDResponse_AutoFromDoc_AllRootFieldsPopulated(t *testing.T) {
	got := fwresponses.AutoFromDoc[FindUserByIDResponse](realComposerDoc())
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
	got := fwresponses.AutoFromDoc[FindUserByIDResponse](realComposerDoc())
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
		t.Errorf("Addr.ZipCode (view:zip_code rename): want 95014, got %q", a.ZipCode)
	}
	if a.Country != "US" {
		t.Errorf("Addr.Country: want US, got %q", a.Country)
	}
}

func TestFindUserByIDResponse_AutoFromDoc_FallsBackToUnderscoreID(t *testing.T) {
	doc := map[string]any{
		"_id":   "user-2",
		"name":  "Bob",
		"email": "bob@example.com",
	}
	got := fwresponses.AutoFromDoc[FindUserByIDResponse](doc)
	if got.ID != "user-2" {
		t.Errorf("expected ID from _id fallback, got %q", got.ID)
	}
}

func TestFindUserByIDResponse_AutoFromDoc_NilAddressesBecomeEmptySlice(t *testing.T) {
	doc := map[string]any{
		"id":    "user-3",
		"name":  "Carol",
		"email": "carol@example.com",
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
		"id":    "user-4",
		"name":  "Dave",
		"email": "dave@example.com",
	}
	got := fwresponses.AutoFromDoc[FindUserByIDResponse](doc)
	if got.Phone != nil {
		t.Errorf("expected nil Phone when absent, got %v", got.Phone)
	}
}
