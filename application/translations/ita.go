package translations

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/translation"
)

type ita struct{}

// ITA returns the Italian translation module for this service's custom
// notifications. Register alongside translation.CoreIT() at startup.
func ITA() translation.Module { return ita{} }

func (ita) Language() configuration.Language { return configuration.LangIT }

func (ita) Translations() map[string]string {
	return map[string]string{
		"InvalidEmailNotification":       "Email non valida.",
		"InvalidPhoneNotification":       "Numero di telefono non valido.",
		"InvalidStateNotification":       "Regione non valida.",
		"InvalidZipCodeNotification":     "Codice postale non valido.",
		"InvalidCountryNotification":     "Paese non valido (usa il codice ISO a 2 lettere).",
		"EmailAlreadyExistsNotification": "Email già registrata.",
		"EmailCannotChangeNotification":  "L'email non può essere modificata dopo la creazione dell'utente.",
		"DuplicateAddressNotification":   "Indirizzo duplicato per questo utente.",
	}
}
