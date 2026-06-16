package translations

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/translation"
)

type fra struct{}

// FRA returns the French translation module for this service's custom
// notifications. Register alongside translation.CoreFR() at startup.
func FRA() translation.Module { return fra{} }

func (fra) Language() configuration.Language { return configuration.LangFR }

func (fra) Translations() map[string]string {
	return map[string]string{
		"InvalidEmailNotification":       "E-mail invalide.",
		"InvalidPhoneNotification":       "Numéro de téléphone invalide.",
		"InvalidStateNotification":       "État invalide.",
		"InvalidZipCodeNotification":     "Code postal invalide.",
		"InvalidCountryNotification":     "Pays invalide (utilisez le code ISO à 2 lettres).",
		"EmailAlreadyExistsNotification": "E-mail déjà enregistré.",
		"EmailCannotChangeNotification":  "L'e-mail ne peut pas être modifié après la création de l'utilisateur.",
		"DuplicateAddressNotification":      "Adresse en doublon pour cet utilisateur.",
		"NameMaxLengthExceededNotification": "Le nom dépasse la longueur maximale autorisée de {maxLength} caractères.",
		"User":                              "Utilisateur",
		// Field labels — see ptbr.go for the per-locale rationale.
		"UserNameField":            "Nom",
		"UserEmailField":           "Adresse e-mail",
		"UserPhoneField":           "Téléphone",
		"AddressLabelField":        "Libellé",
		"AddressStreetField":       "Rue",
		"AddressNumberField":       "Numéro",
		"AddressComplementField":   "Complément",
		"AddressNeighborhoodField": "Quartier",
		"AddressCityField":         "Ville",
		"AddressStateField":        "Région",
		"AddressZipCodeField":      "Code postal",
		"AddressCountryField":      "Pays",
	}
}
