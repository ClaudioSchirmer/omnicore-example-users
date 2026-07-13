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
		"InvalidEmailNotification":          "E-mail invalide.",
		"InvalidPhoneNotification":          "Numéro de téléphone invalide.",
		"InvalidDocumentNotification":       "Document invalide.",
		"InvalidStateNotification":          "État invalide.",
		"InvalidZipCodeNotification":        "Code postal invalide.",
		"InvalidCountryNotification":        "Pays invalide (utilisez le code ISO à 2 lettres).",
		"DocumentCannotChangeNotification":  "Le document ne peut pas être modifié après la création de l'utilisateur.",
		"DuplicateAddressNotification":      "Adresse en doublon pour cet utilisateur.",
		"ProductCategoryLimitNotification":  "Limite de catégories de produits distinctes atteinte.",
		"NameMaxLengthExceededNotification": "Le nom dépasse la longueur maximale autorisée de {maxLength} caractères.",
		"User":                              "Utilisateur",
		// Field labels — see ptbr.go for the per-locale rationale.
		"UserNameField":              "Nom",
		"UserEmailField":             "Adresse e-mail",
		"UserPhoneField":             "Téléphone",
		"UserDocumentField":          "Document",
		"UserUserNameField":          "Nom d'utilisateur",
		"UserEmailNotificationField": "Notification par e-mail",
		"UserSmsNotificationField":   "Notification par SMS",
		"AddressLabelField":          "Libellé",
		"AddressStreetField":         "Rue",
		"AddressNumberField":         "Numéro",
		"AddressComplementField":     "Complément",
		"AddressNeighborhoodField":   "Quartier",
		"AddressCityField":           "Ville",
		"AddressStateField":          "Région",
		"AddressZipCodeField":        "Code postal",
		"AddressCountryField":        "Pays",
		// Agrégat Employee — libellé de contexte, libellés de champ et notifications.
		"Employee":                          "Employé",
		"EmployeeNumberField":               "Matricule",
		"EmployeeBankField":                 "Banque",
		"EmployeeBranchField":               "Agence",
		"EmployeeAccountField":              "Compte",
		"EmployeePixField":                  "Clé Pix",
		"DependentNameField":                "Nom de la personne à charge",
		"DependentBirthDateField":           "Date de naissance",
		"DependentRelationshipField":        "Lien de parenté",
		"DependentHealthPlanProviderField":  "Assureur santé",
		"DependentHealthPlanCardField":      "Carte d'assurance santé",
		"DependentHealthPlanExpiryField":    "Validité de l'assurance santé",
		"JobHistoryJobTitleField":           "Poste",
		"JobHistoryDepartmentField":         "Département",
		"JobHistoryHiredAtField":            "Date d'embauche",
		"JobHistoryTerminatedAtField":       "Date de départ",
		"InvalidRelationshipNotification":   "Lien de parenté invalide (utilisez spouse, son, daughter, father, mother ou other).",
		"TerminationBeforeHireNotification": "La date de départ ne peut pas précéder la date d'embauche.",
	}
}
