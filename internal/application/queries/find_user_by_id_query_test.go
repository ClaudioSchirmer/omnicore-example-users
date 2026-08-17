package queries

import (
	"reflect"
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/vos"
)

func TestFindUserByIDQuery_ToCriteria_IncludeArchivedFalseByDefault(t *testing.T) {
	q := FindUserByIDQuery{}
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	crit, _ := q.ToCriteria(ctx)
	if crit.IncludeArchived {
		t.Error("expected zero-value IncludeArchived to yield IncludeArchived=false")
	}
}

func TestFindUserByIDQuery_ToCriteria_IncludeArchivedFlagPropagates(t *testing.T) {
	q := FindUserByIDQuery{Criteria: fwqueries.ReadCriteria{IncludeArchived: true}}
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	crit, _ := q.ToCriteria(ctx)
	if !crit.IncludeArchived {
		t.Error("expected IncludeArchived=true to set IncludeArchived=true")
	}
}

func TestFindUserByIDQuery_SetPathIDRoundtrip(t *testing.T) {
	q := &FindUserByIDQuery{}
	q.SetPathID("abc")
	if got := q.PathID().Value(); got != "abc" {
		t.Errorf("expected GetID()='abc', got %q", got)
	}
}

func TestFindUserByIDQuery_ContextNameIsUser(t *testing.T) {
	if got := (FindUserByIDQuery{}).ContextName(); got != "User" {
		t.Errorf("expected ContextName()=\"User\", got %q", got)
	}
}

// TestFindUserByIDResult_OutOfSetEnumsConvergeToUnknown locks the convergence
// contract at the seat that owns it: the doc→Result fill runs in the
// APPLICATION layer, below every transport boundary, so a stored value outside
// an enum value object's declared set becomes the Unknown sentinel once — and
// REST, gRPC, GraphQL and the CSV/XLSX exports all inherit the same value.
// Covers a string-backed enum, an int-backed one, an optional one, and a
// nested enum inside the address array.
func TestFindUserByIDResult_OutOfSetEnumsConvergeToUnknown(t *testing.T) {
	got := fwqueries.ResultFromDoc[FindUserByIDResult](map[string]any{
		"ID":                    "user-1",
		"Ethnicity":             "martian",
		"UserProfile":           99,
		"NotificationFrequency": 77,
		"Addresses": []any{
			map[string]any{"ID": "addr-1", "AddressType": "orbital"},
		},
	})

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

// TestFindUserByIDResult_DeclaredEnumMembersSurviveTheFill is the counterpart:
// a value inside the declared set passes through untouched, so convergence
// never rewrites legitimate data.
func TestFindUserByIDResult_DeclaredEnumMembersSurviveTheFill(t *testing.T) {
	got := fwqueries.ResultFromDoc[FindUserByIDResult](map[string]any{
		"ID":          "user-1",
		"Ethnicity":   string(vos.EthnicityWhite),
		"UserProfile": int(vos.UserProfileManager),
	})
	if got.Ethnicity != vos.EthnicityWhite {
		t.Errorf("Ethnicity: want white, got %q", got.Ethnicity)
	}
	if got.UserProfile != vos.UserProfileManager {
		t.Errorf("UserProfile: want %d, got %d", vos.UserProfileManager, got.UserProfile)
	}
}

// TestFindUserByIDQuery_FromQueryIsPassthrough locks the mandatory read-side
// projection seat every Query now carries (the twin of a command's
// FromEntity). This read computes nothing, so the filled Result must reach the
// transports byte-identical — the assertion that would break the day a
// derivation is added here without a test to describe it.
func TestFindUserByIDQuery_FromQueryIsPassthrough(t *testing.T) {
	ctx := configuration.NewAppContextWithRandomID(configuration.LangPTBR)
	phone := "14155552671"
	in := FindUserByIDResult{
		ID:        "user-1",
		Name:      "Jane",
		Phone:     &phone,
		Ethnicity: vos.EthnicityWhite,
		Addresses: []AddressResult{{ID: "addr-1", City: "Cupertino"}},
	}

	out, err := FindUserByIDQuery{}.FromQueryResult(ctx, in)
	if err != nil {
		t.Fatalf("FromQueryResult: %v", err)
	}
	if !reflect.DeepEqual(out, in) {
		t.Errorf("FromQueryResult must pass the filled Result through unchanged:\n got %+v\nwant %+v", out, in)
	}
}
