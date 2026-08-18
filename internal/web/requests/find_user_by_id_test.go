package requests

import (
	"encoding/json"
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/vos"
)

func TestFindUserByIDRequest_IncludeArchivedUnsetDefaultsFalse(t *testing.T) {
	q := FindUserByIDRequest{}.ToQuery(fwqueries.ReadCriteria{})
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	crit, _ := q.ToCriteria(ctx)
	if crit.IncludeArchived {
		t.Error("expected IncludeArchived=false when the wire carried no control")
	}
}

func TestFindUserByIDRequest_IncludeArchivedTrue(t *testing.T) {
	q := FindUserByIDRequest{}.ToQuery(fwqueries.ReadCriteria{IncludeArchived: true})
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	crit, _ := q.ToCriteria(ctx)
	if !crit.IncludeArchived {
		t.Error("expected IncludeArchived=true to survive ToQuery→ToCriteria")
	}
}

func TestFindUserByIDRequest_IncludeArchivedFalseIsExplicitFalse(t *testing.T) {
	q := FindUserByIDRequest{}.ToQuery(fwqueries.ReadCriteria{IncludeArchived: false})
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	crit, _ := q.ToCriteria(ctx)
	if crit.IncludeArchived {
		t.Error("expected IncludeArchived=false when the wire said false")
	}
}

// readerGoDoc returns a fixture mirroring what the MongoViewReader hands to the
// projector: Go-field-name keys, not physical columns. The composer writes
// physical columns (zip_code, the embed under "addresses") to Mongo; the reader
// translates each leaf back via UserSchema()/AddressSchema() (zip_code →
// ZipCode) and the embed doc field "addresses" → the Go segment "Addresses"
// before the Result is filled. So the fixture speaks Go names.
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

// responseFromDoc walks the two hops the remodel installed between the reader
// document and the wire: the framework fills the application-layer Result
// (fwqueries.ResultFromDoc — what the query handler does), and the Response's
// FromResult maps it onto the wire shape. The canonical document stops at the
// application boundary, so a doc→wire assertion must cross both.
func responseFromDoc(doc map[string]any) FindUserByIDResponse {
	result := fwqueries.ResultFromDoc[queries.FindUserByIDResult](doc)
	return FindUserByIDResponse{}.FromResult(result)
}

func TestFindUserByIDResponse_FromResult_AllRootFieldsPopulated(t *testing.T) {
	got := responseFromDoc(readerGoDoc())
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

func TestFindUserByIDResponse_FromResult_AllAddressFieldsPopulated(t *testing.T) {
	got := responseFromDoc(readerGoDoc())
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

func TestFindUserByIDResponse_FromResult_FallsBackToUnderscoreID(t *testing.T) {
	doc := map[string]any{
		"_id":   "user-2",
		"Name":  "Bob",
		"Email": "bob@example.com",
	}
	got := responseFromDoc(doc)
	if got.ID != "user-2" {
		t.Errorf("expected ID from _id fallback, got %q", got.ID)
	}
}

func TestFindUserByIDResponse_FromResult_NilAddressesBecomeEmptySlice(t *testing.T) {
	doc := map[string]any{
		"ID":    "user-3",
		"Name":  "Carol",
		"Email": "carol@example.com",
	}
	got := responseFromDoc(doc)
	if got.Addresses == nil {
		t.Error("expected non-nil Addresses slice for missing addresses key")
	}
	if len(got.Addresses) != 0 {
		t.Errorf("expected empty Addresses, got %d", len(got.Addresses))
	}
}

func TestFindUserByIDResponse_FromResult_OptionalsOmittedWhenAbsent(t *testing.T) {
	doc := map[string]any{
		"ID":    "user-4",
		"Name":  "Dave",
		"Email": "dave@example.com",
	}
	got := responseFromDoc(doc)
	if got.Phone != nil {
		t.Errorf("expected nil Phone when absent, got %v", got.Phone)
	}
}

// TestFindUserByIDResponse_FromResult_RenamesOntoWireNames locks the seat
// FromResult now owns. The Result is application-pure — Go field names, NO
// wire tags — so the Response's json tags are the single declaration of the
// wire vocabulary. Marshalling the mapped Response must emit those names at
// the root and inside the nested address, never the Result's Go names.
func TestFindUserByIDResponse_FromResult_RenamesOntoWireNames(t *testing.T) {
	notifyEmail := vos.Email("alice.notify@example.com")
	freq := vos.NotificationFrequencyDaily
	result := queries.FindUserByIDResult{
		ID:                    "user-1",
		Name:                  "Jane",
		UserName:              "jane",
		UserProfile:           vos.UserProfileAdmin,
		Ethnicity:             vos.EthnicityWhite,
		NotificationEmail:     &notifyEmail,
		NotificationFrequency: &freq,
		Addresses: []queries.AddressResult{
			{ID: "addr-1", ZipCode: "95014", AddressType: vos.AddressTypeResidential},
		},
	}

	raw, err := json.Marshal(FindUserByIDResponse{}.FromResult(result))
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
		"NotificationEmail":     "notificationEmail",
		"NotificationFrequency": "notificationFrequency",
	} {
		if _, ok := wire[goName]; ok {
			t.Errorf("the Result's Go name %q must not reach the wire", goName)
		}
		if _, ok := wire[wireName]; !ok {
			t.Errorf("expected wire key %q, got %v", wireName, wire)
		}
	}
	if wire["userName"] != "jane" || wire["ethnicity"] != "white" {
		t.Errorf("root values not carried under their json names: %v", wire)
	}
	// Value-object-typed fields render as their underlying scalar.
	if wire["userProfile"] != float64(vos.UserProfileAdmin) {
		t.Errorf("userProfile: want %d, got %v", vos.UserProfileAdmin, wire["userProfile"])
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

// TestFindUserByIDResponse_FromResult_OutOfSetEnumsConvergeToUnknown proves the
// convergence the remodel moved into the application layer reaches this wire
// unchanged: a stored value outside an enum value object's declared set
// becomes the Unknown sentinel at the fill, so REST renders exactly what gRPC,
// GraphQL and the exports render. Covers a string-backed enum (Ethnicity), an
// int-backed one (UserProfile), an OPTIONAL one (NotificationFrequency) and a
// nested enum inside the address array.
func TestFindUserByIDResponse_FromResult_OutOfSetEnumsConvergeToUnknown(t *testing.T) {
	doc := map[string]any{
		"ID":                    "user-5",
		"Name":                  "Eve",
		"Ethnicity":             "martian",
		"UserProfile":           99,
		"NotificationFrequency": 77,
		"Addresses": []any{
			map[string]any{"ID": "addr-1", "AddressType": "orbital"},
		},
	}
	got := responseFromDoc(doc)

	if got.Ethnicity != vos.EthnicityUnknown {
		t.Errorf("Ethnicity: want the Unknown sentinel, got %q", got.Ethnicity)
	}
	if got.UserProfile != vos.UserProfileUnknown {
		t.Errorf("UserProfile: want the Unknown sentinel, got %d", got.UserProfile)
	}
	if got.NotificationFrequency == nil || *got.NotificationFrequency != vos.NotificationFrequencyUnknown {
		t.Errorf("NotificationFrequency: want the Unknown sentinel, got %v", got.NotificationFrequency)
	}
	if len(got.Addresses) != 1 || got.Addresses[0].AddressType != vos.AddressTypeUnknown {
		t.Errorf("nested AddressType: want the Unknown sentinel, got %+v", got.Addresses)
	}
}

// TestFindUserByIDResponse_FromResult_AbsentOptionalEnumStaysNil is the
// counterpart of the convergence rule: an ABSENT optional enum is absence, not
// Unknown — the pointer stays nil and omitempty elides it.
func TestFindUserByIDResponse_FromResult_AbsentOptionalEnumStaysNil(t *testing.T) {
	got := responseFromDoc(map[string]any{"ID": "user-6", "Name": "Frank"})
	if got.NotificationFrequency != nil {
		t.Errorf("expected nil NotificationFrequency when absent, got %v", got.NotificationFrequency)
	}
	if got.NotificationEmail != nil {
		t.Errorf("expected nil NotificationEmail when absent, got %v", got.NotificationEmail)
	}
}
