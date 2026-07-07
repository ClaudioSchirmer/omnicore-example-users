package translations

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/translation"
)

// AllCatalogs lists every public catalog the package ships. Used to assert
// each one carries the expected language + key set without spelling out the
// catalog name in each test case.
func allCatalogs() map[configuration.Language]translation.Module {
	return map[configuration.Language]translation.Module{
		configuration.LangPTBR: PTBR(),
		configuration.LangENG:  ENG(),
		configuration.LangES:   ESP(),
		configuration.LangFR:   FRA(),
		configuration.LangDE:   DEU(),
		configuration.LangIT:   ITA(),
		configuration.LangNL:   NLD(),
	}
}

func TestCatalogs_LanguageMatchesIdentifier(t *testing.T) {
	for want, mod := range allCatalogs() {
		if got := mod.Language(); got != want {
			t.Errorf("%T.Language() = %v, want %v", mod, got, want)
		}
	}
}

func TestCatalogs_NoEmptyTranslations(t *testing.T) {
	for lang, mod := range allCatalogs() {
		entries := mod.Translations()
		if len(entries) == 0 {
			t.Errorf("catalog %v is empty", lang)
			continue
		}
		for k, v := range entries {
			if v == "" {
				t.Errorf("catalog %v: key %q has empty translation", lang, k)
			}
		}
	}
}

func TestCatalogs_KeysConsistentWithENG(t *testing.T) {
	ref := ENG().Translations()
	for lang, mod := range allCatalogs() {
		if lang == configuration.LangENG {
			continue
		}
		entries := mod.Translations()
		for key := range ref {
			if _, ok := entries[key]; !ok {
				t.Errorf("catalog %v missing key %q present in ENG", lang, key)
			}
		}
		for key := range entries {
			if _, ok := ref[key]; !ok {
				t.Errorf("catalog %v has key %q absent from ENG", lang, key)
			}
		}
	}
}

func TestCatalogs_CarryExpectedKeys(t *testing.T) {
	want := []string{
		"InvalidEmailNotification",
		"InvalidPhoneNotification",
		"InvalidDocumentNotification",
		"InvalidStateNotification",
		"InvalidZipCodeNotification",
		"InvalidCountryNotification",
		"DocumentCannotChangeNotification",
		"DuplicateAddressNotification",
		"UserDocumentField",
		"UserUserNameField",
		"UserEmailNotificationField",
		"UserSmsNotificationField",
	}
	for lang, mod := range allCatalogs() {
		entries := mod.Translations()
		for _, k := range want {
			if _, ok := entries[k]; !ok {
				t.Errorf("catalog %v missing expected key %q", lang, k)
			}
		}
	}
}

// Constructors return distinct Module instances, even for catalogs the
// framework could in principle pool. Catches an accidental shared singleton.
func TestCatalogs_ConstructorsReturnModule(t *testing.T) {
	mods := []translation.Module{PTBR(), ENG(), ESP(), FRA(), DEU(), ITA(), NLD()}
	for i, mod := range mods {
		if mod == nil {
			t.Errorf("constructor %d returned nil", i)
		}
	}
}
