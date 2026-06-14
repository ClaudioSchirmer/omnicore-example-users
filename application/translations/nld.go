package translations

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/translation"
)

type nld struct{}

// NLD returns the Dutch translation module for this service's custom
// notifications. Register alongside translation.CoreNL() at startup.
func NLD() translation.Module { return nld{} }

func (nld) Language() configuration.Language { return configuration.LangNL }

func (nld) Translations() map[string]string {
	return map[string]string{
		"InvalidEmailNotification":       "Ongeldig e-mailadres.",
		"InvalidPhoneNotification":       "Ongeldig telefoonnummer.",
		"InvalidStateNotification":       "Ongeldige provincie.",
		"InvalidZipCodeNotification":     "Ongeldige postcode.",
		"InvalidCountryNotification":     "Ongeldig land (gebruik de 2-letterige ISO-code).",
		"EmailAlreadyExistsNotification": "E-mailadres is al geregistreerd.",
		"EmailCannotChangeNotification":  "Het e-mailadres kan niet worden gewijzigd na het aanmaken van de gebruiker.",
		"DuplicateAddressNotification":   "Dubbel adres voor deze gebruiker.",
	}
}
