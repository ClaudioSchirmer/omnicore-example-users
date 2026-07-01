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
		"InvalidEmailNotification":          "Email non valida.",
		"InvalidPhoneNotification":          "Numero di telefono non valido.",
		"InvalidDocumentNotification":       "Documento non valido.",
		"InvalidStateNotification":          "Regione non valida.",
		"InvalidZipCodeNotification":        "Codice postale non valido.",
		"InvalidCountryNotification":        "Paese non valido (usa il codice ISO a 2 lettere).",
		"DocumentCannotChangeNotification":  "Il documento non può essere modificato dopo la creazione dell'utente.",
		"DuplicateAddressNotification":      "Indirizzo duplicato per questo utente.",
		"NameMaxLengthExceededNotification": "Il nome supera la lunghezza massima consentita di {maxLength} caratteri.",
		"User":                              "Utente",
		// Field labels — see ptbr.go for the per-locale rationale.
		"UserNameField":              "Nome",
		"UserEmailField":             "E-mail",
		"UserPhoneField":             "Telefono",
		"UserDocumentField":          "Documento",
		"UserUserNameField":          "Nome utente",
		"UserEmailNotificationField": "Notifica e-mail",
		"UserSmsNotificationField":   "Notifica SMS",
		"AddressLabelField":          "Etichetta",
		"AddressStreetField":         "Via",
		"AddressNumberField":         "Numero",
		"AddressComplementField":     "Complemento",
		"AddressNeighborhoodField":   "Quartiere",
		"AddressCityField":           "Città",
		"AddressStateField":          "Provincia",
		"AddressZipCodeField":        "CAP",
		"AddressCountryField":        "Paese",
	}
}
