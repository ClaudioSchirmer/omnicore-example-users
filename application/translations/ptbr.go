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
		// Field labels — humanizam o identificador do campo na superfície
		// reativa (MessageDTO.FieldLabel + render-at-read no audit via
		// FieldChange.FieldLabelKey). Mapeamento 1:1 com as tags `label:"..."`
		// declaradas em domain/user.go e domain/address.go. Lidos pelo
		// framework no momento da emissão da notification e no audit_builder;
		// canais sem frontend (e-mail, SMS, push, leitura de auditoria) leem
		// o envelope direto e enxergam "CEP" em vez de
		// "addresses[0].zipCode".
		"UserNameField":            "Nome",
		"UserEmailField":           "E-mail",
		"UserPhoneField":           "Telefone",
		"AddressLabelField":        "Rótulo",
		"AddressStreetField":       "Rua",
		"AddressNumberField":       "Número",
		"AddressComplementField":   "Complemento",
		"AddressNeighborhoodField": "Bairro",
		"AddressCityField":         "Cidade",
		"AddressStateField":        "Estado",
		"AddressZipCodeField":      "CEP",
		"AddressCountryField":      "País",
	}
}
