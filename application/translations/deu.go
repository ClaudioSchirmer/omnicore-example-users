package translations

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/translation"
)

type deu struct{}

// DEU returns the German translation module for this service's custom
// notifications. Register alongside translation.CoreDE() at startup.
func DEU() translation.Module { return deu{} }

func (deu) Language() configuration.Language { return configuration.LangDE }

func (deu) Translations() map[string]string {
	return map[string]string{
		"InvalidEmailNotification":          "Ungültige E-Mail-Adresse.",
		"InvalidPhoneNotification":          "Ungültige Telefonnummer.",
		"InvalidDocumentNotification":       "Ungültiges Dokument.",
		"InvalidStateNotification":          "Ungültiges Bundesland.",
		"InvalidZipCodeNotification":        "Ungültige Postleitzahl.",
		"InvalidCountryNotification":        "Ungültiges Land (verwenden Sie den 2-stelligen ISO-Code).",
		"DocumentCannotChangeNotification":  "Das Dokument kann nach der Erstellung des Benutzers nicht geändert werden.",
		"DuplicateAddressNotification":      "Doppelte Adresse für diesen Benutzer.",
		"NameMaxLengthExceededNotification": "Der Name überschreitet die maximal zulässige Länge von {maxLength} Zeichen.",
		"User":                              "Benutzer",
		// Field labels — see ptbr.go for the per-locale rationale.
		"UserNameField":              "Name",
		"UserEmailField":             "E-Mail-Adresse",
		"UserPhoneField":             "Telefon",
		"UserDocumentField":          "Dokument",
		"UserUserNameField":          "Benutzername",
		"UserEmailNotificationField": "E-Mail-Benachrichtigung",
		"UserSmsNotificationField":   "SMS-Benachrichtigung",
		"AddressLabelField":          "Bezeichnung",
		"AddressStreetField":         "Straße",
		"AddressNumberField":         "Hausnummer",
		"AddressComplementField":     "Adresszusatz",
		"AddressNeighborhoodField":   "Stadtteil",
		"AddressCityField":           "Stadt",
		"AddressStateField":          "Bundesland",
		"AddressZipCodeField":        "Postleitzahl",
		"AddressCountryField":        "Land",
		// Employee-Aggregat — Kontextbezeichnung, Feldbezeichnungen und Benachrichtigungen.
		"Employee":                          "Mitarbeiter",
		"EmployeeNumberField":               "Personalnummer",
		"EmployeeBankField":                 "Bank",
		"EmployeeBranchField":               "Filiale",
		"EmployeeAccountField":              "Konto",
		"EmployeePixField":                  "Pix-Schlüssel",
		"DependentNameField":                "Name des Angehörigen",
		"DependentBirthDateField":           "Geburtsdatum",
		"DependentRelationshipField":        "Verwandtschaftsgrad",
		"DependentHealthPlanProviderField":  "Krankenversicherer",
		"DependentHealthPlanCardField":      "Versichertenkarte",
		"DependentHealthPlanExpiryField":    "Gültigkeit der Versicherung",
		"JobHistoryJobTitleField":           "Position",
		"JobHistoryDepartmentField":         "Abteilung",
		"JobHistoryHiredAtField":            "Einstellungsdatum",
		"JobHistoryTerminatedAtField":       "Austrittsdatum",
		"InvalidRelationshipNotification":   "Ungültiger Verwandtschaftsgrad (verwenden Sie spouse, son, daughter, father, mother oder other).",
		"TerminationBeforeHireNotification": "Das Austrittsdatum darf nicht vor dem Einstellungsdatum liegen.",
	}
}
