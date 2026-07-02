package translations

import (
	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/translation"
)

type eng struct{}

func ENG() translation.Module { return eng{} }

func (eng) Language() configuration.Language { return configuration.LangENG }

func (eng) Translations() map[string]string {
	return map[string]string{
		"InvalidEmailNotification":         "Invalid email.",
		"InvalidPhoneNotification":         "Invalid phone number.",
		"InvalidDocumentNotification":      "Invalid document.",
		"InvalidStateNotification":         "Invalid state.",
		"InvalidZipCodeNotification":       "Invalid postal code.",
		"InvalidCountryNotification":       "Invalid country (use 2-letter ISO code).",
		"DocumentCannotChangeNotification": "Document cannot be changed after the user is created.",
		"DuplicateAddressNotification":     "Duplicate address for this user.",
		// Parameterized notification — {maxLength} is substituted at render time
		// from the tvar:"maxLength" tag on the notification struct.
		"NameMaxLengthExceededNotification": "Name exceeds the maximum allowed length of {maxLength} characters.",
		// Context-label entry — closes a pre-existing gap where the framework
		// has always translated NotificationContext.context but the example
		// never declared the entry, so the literal Go struct name "User"
		// reached the wire envelope. With this entry registered, the wire
		// `context` field renders translated per Accept-Language.
		"User": "User",
		// Field labels — human-readable names for the fields the domain
		// declares via the `labelKey:"..."` struct tag. Mirrored across all
		// seven catalogs; see ptbr.go for the per-locale rationale.
		"UserNameField":              "Name",
		"UserEmailField":             "Email",
		"UserPhoneField":             "Phone",
		"UserDocumentField":          "Document",
		"UserUserNameField":          "Username",
		"UserEmailNotificationField": "Email notification",
		"UserSmsNotificationField":   "SMS notification",
		"AddressLabelField":          "Label",
		"AddressStreetField":         "Street",
		"AddressNumberField":         "Number",
		"AddressComplementField":     "Complement",
		"AddressNeighborhoodField":   "Neighborhood",
		"AddressCityField":           "City",
		"AddressStateField":          "State",
		"AddressZipCodeField":        "ZIP Code",
		"AddressCountryField":        "Country",
		// Employee aggregate — context label, field labels, notifications.
		// The domain vocabulary is Portuguese by design (approved spec); the
		// catalogs translate it per locale like any other key.
		"Employee":                          "Employee",
		"EmployeeNumberField":               "Employee number",
		"EmployeeBankField":                 "Bank",
		"EmployeeBranchField":               "Branch",
		"EmployeeAccountField":              "Account",
		"EmployeePixField":                  "Pix key",
		"DependentNameField":                "Dependent name",
		"DependentBirthDateField":           "Date of birth",
		"DependentRelationshipField":        "Relationship",
		"DependentHealthPlanProviderField":  "Health plan provider",
		"DependentHealthPlanCardField":      "Health plan card",
		"DependentHealthPlanExpiryField":    "Health plan expiry",
		"JobHistoryJobTitleField":           "Job title",
		"JobHistoryDepartmentField":         "Department",
		"JobHistoryHiredAtField":            "Hire date",
		"JobHistoryTerminatedAtField":       "Termination date",
		"InvalidRelationshipNotification":   "Invalid relationship (use spouse, son, daughter, father, mother or other).",
		"TerminationBeforeHireNotification": "Termination date cannot be before the hire date.",
	}
}
