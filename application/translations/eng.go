package translations

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/translation"
)

type eng struct{}

func ENG() translation.Module { return eng{} }

func (eng) Language() configuration.Language { return configuration.LangENG }

func (eng) Translations() map[string]string {
	return map[string]string{
		"InvalidEmailNotification":       "Invalid email.",
		"InvalidPhoneNotification":       "Invalid phone number.",
		"InvalidStateNotification":       "Invalid state.",
		"InvalidZipCodeNotification":     "Invalid postal code.",
		"InvalidCountryNotification":     "Invalid country (use 2-letter ISO code).",
		"EmailAlreadyExistsNotification": "Email already registered.",
		"EmailCannotChangeNotification":  "Email cannot be changed after the user is created.",
		"DuplicateAddressNotification":   "Duplicate address for this user.",
	}
}
