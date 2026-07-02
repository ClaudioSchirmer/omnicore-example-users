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
		"InvalidEmailNotification":          "Ongeldig e-mailadres.",
		"InvalidPhoneNotification":          "Ongeldig telefoonnummer.",
		"InvalidDocumentNotification":       "Ongeldig document.",
		"InvalidStateNotification":          "Ongeldige provincie.",
		"InvalidZipCodeNotification":        "Ongeldige postcode.",
		"InvalidCountryNotification":        "Ongeldig land (gebruik de 2-letterige ISO-code).",
		"DocumentCannotChangeNotification":  "Het document kan niet worden gewijzigd na het aanmaken van de gebruiker.",
		"DuplicateAddressNotification":      "Dubbel adres voor deze gebruiker.",
		"NameMaxLengthExceededNotification": "Naam overschrijdt de maximaal toegestane lengte van {maxLength} tekens.",
		"User":                              "Gebruiker",
		// Field labels — see ptbr.go for the per-locale rationale.
		"UserNameField":              "Naam",
		"UserEmailField":             "E-mailadres",
		"UserPhoneField":             "Telefoon",
		"UserDocumentField":          "Document",
		"UserUserNameField":          "Gebruikersnaam",
		"UserEmailNotificationField": "E-mailmelding",
		"UserSmsNotificationField":   "Sms-melding",
		"AddressLabelField":          "Label",
		"AddressStreetField":         "Straat",
		"AddressNumberField":         "Huisnummer",
		"AddressComplementField":     "Adresaanvulling",
		"AddressNeighborhoodField":   "Wijk",
		"AddressCityField":           "Stad",
		"AddressStateField":          "Provincie",
		"AddressZipCodeField":        "Postcode",
		"AddressCountryField":        "Land",
		// Employee-aggregaat — contextlabel, veldlabels en meldingen.
		"Employee":                          "Medewerker",
		"EmployeeNumberField":               "Personeelsnummer",
		"EmployeeBankField":                 "Bank",
		"EmployeeBranchField":               "Filiaal",
		"EmployeeAccountField":              "Rekening",
		"EmployeePixField":                  "Pix-sleutel",
		"DependentNameField":                "Naam van gezinslid",
		"DependentBirthDateField":           "Geboortedatum",
		"DependentRelationshipField":        "Verwantschap",
		"DependentHealthPlanProviderField":  "Zorgverzekeraar",
		"DependentHealthPlanCardField":      "Zorgpas",
		"DependentHealthPlanExpiryField":    "Geldigheid zorgplan",
		"JobHistoryJobTitleField":           "Functie",
		"JobHistoryDepartmentField":         "Afdeling",
		"JobHistoryHiredAtField":            "Datum indiensttreding",
		"JobHistoryTerminatedAtField":       "Datum uitdiensttreding",
		"InvalidRelationshipNotification":   "Ongeldige verwantschap (gebruik spouse, son, daughter, father, mother of other).",
		"TerminationBeforeHireNotification": "De datum van uitdiensttreding kan niet vóór de indiensttreding liggen.",
	}
}
