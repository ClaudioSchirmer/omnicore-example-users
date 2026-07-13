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
		"InvalidEmailNotification":         "E-mail inválido.",
		"InvalidPhoneNotification":         "Telefone inválido.",
		"InvalidDocumentNotification":      "Documento inválido.",
		"InvalidStateNotification":         "Estado inválido.",
		"InvalidZipCodeNotification":       "Código postal inválido.",
		"InvalidCountryNotification":       "País inválido (use código ISO de 2 letras).",
		"DocumentCannotChangeNotification": "O documento não pode ser alterado após a criação do usuário.",
		"DuplicateAddressNotification":     "Endereço duplicado neste usuário.",
		"ProductCategoryLimitNotification": "Limite de categorias de produto distintas atingido.",
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
		// FieldChange.FieldLabelKey). Mapeamento 1:1 com as tags `labelKey:"..."`
		// declaradas em domain/user.go e domain/address.go. Lidos pelo
		// framework no momento da emissão da notification e no audit_builder;
		// canais sem frontend (e-mail, SMS, push, leitura de auditoria) leem
		// o envelope direto e enxergam "CEP" em vez de
		// "addresses[0].zipCode".
		"UserNameField":              "Nome",
		"UserEmailField":             "E-mail",
		"UserPhoneField":             "Telefone",
		"UserDocumentField":          "Documento",
		"UserUserNameField":          "Nome de usuário",
		"UserEmailNotificationField": "Notificação por e-mail",
		"UserSmsNotificationField":   "Notificação por SMS",
		"AddressLabelField":          "Rótulo",
		"AddressStreetField":         "Rua",
		"AddressNumberField":         "Número",
		"AddressComplementField":     "Complemento",
		"AddressNeighborhoodField":   "Bairro",
		"AddressCityField":           "Cidade",
		"AddressStateField":          "Estado",
		"AddressZipCodeField":        "CEP",
		"AddressCountryField":        "País",
		// Agregado Employee — rótulo de contexto, rótulos de campo e notificações.
		"Employee":                          "Funcionário",
		"EmployeeNumberField":               "Matrícula",
		"EmployeeBankField":                 "Banco",
		"EmployeeBranchField":               "Agência",
		"EmployeeAccountField":              "Conta",
		"EmployeePixField":                  "Chave Pix",
		"DependentNameField":                "Nome do dependente",
		"DependentBirthDateField":           "Data de nascimento",
		"DependentRelationshipField":        "Parentesco",
		"DependentHealthPlanProviderField":  "Operadora do plano",
		"DependentHealthPlanCardField":      "Carteirinha do plano",
		"DependentHealthPlanExpiryField":    "Validade do plano",
		"JobHistoryJobTitleField":           "Cargo",
		"JobHistoryDepartmentField":         "Department",
		"JobHistoryHiredAtField":            "Data de admissão",
		"JobHistoryTerminatedAtField":       "Data de desligamento",
		"InvalidRelationshipNotification":   "Parentesco inválido (use spouse, son, daughter, father, mother ou other).",
		"TerminationBeforeHireNotification": "A data de desligamento não pode ser anterior à admissão.",
	}
}
