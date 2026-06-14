package translations

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/translation"
)

type ptbr struct{}

// PTBR returns the Portuguese (Brazil) translation module for this service's
// custom notifications. Register alongside translation.CorePTBR() at startup.
func PTBR() translation.Module { return ptbr{} }

func (ptbr) Language() configuration.Language { return configuration.LangPTBR }

func (ptbr) Translations() map[string]string {
	return map[string]string{
		"InvalidEmailNotification":       "E-mail inválido.",
		"InvalidPhoneNotification":       "Telefone inválido.",
		"InvalidStateNotification":       "Estado inválido.",
		"InvalidZipCodeNotification":     "Código postal inválido.",
		"InvalidCountryNotification":     "País inválido (use código ISO de 2 letras).",
		"EmailAlreadyExistsNotification": "E-mail já cadastrado.",
		"EmailCannotChangeNotification":  "O e-mail não pode ser alterado após a criação do usuário.",
		"DuplicateAddressNotification":   "Endereço duplicado neste usuário.",
		// Parameterized notification — {maxLength} é substituído em tempo de
		// render pelo valor do campo `tvar:"maxLength"` da notification.
		"NameMaxLengthExceededNotification": "O nome excede o tamanho máximo permitido de {maxLength} caracteres.",
		// Context label — preenche o gap pré-existente em que o framework
		// sempre traduziu NotificationContext.context mas o exemplo nunca
		// declarou a entrada; com isso o campo wire `context` renderiza
		// traduzido conforme Accept-Language.
		"User": "Usuário",
	}
}
