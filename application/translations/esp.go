package translations

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/translation"
)

type esp struct{}

// ESP returns the Spanish translation module for this service's custom
// notifications. Register alongside translation.CoreES() at startup.
func ESP() translation.Module { return esp{} }

func (esp) Language() configuration.Language { return configuration.LangES }

func (esp) Translations() map[string]string {
	return map[string]string{
		"InvalidEmailNotification":       "Email inválido.",
		"InvalidPhoneNotification":       "Número de teléfono inválido.",
		"InvalidStateNotification":       "Estado inválido.",
		"InvalidZipCodeNotification":     "Código postal inválido.",
		"InvalidCountryNotification":     "País inválido (use código ISO de 2 letras).",
		"EmailAlreadyExistsNotification": "Email ya registrado.",
		"EmailCannotChangeNotification":  "El email no puede modificarse después de crear el usuario.",
		"DuplicateAddressNotification":      "Dirección duplicada para este usuario.",
		"NameMaxLengthExceededNotification": "El nombre supera la longitud máxima permitida de {maxLength} caracteres.",
		"User":                              "Usuario",
	}
}
