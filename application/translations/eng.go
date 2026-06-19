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
		"InvalidEmailNotification":       "Invalid email.",
		"InvalidPhoneNotification":       "Invalid phone number.",
		"InvalidStateNotification":       "Invalid state.",
		"InvalidZipCodeNotification":     "Invalid postal code.",
		"InvalidCountryNotification":     "Invalid country (use 2-letter ISO code).",
		"EmailAlreadyExistsNotification": "Email already registered.",
		"EmailCannotChangeNotification":  "Email cannot be changed after the user is created.",
		"DuplicateAddressNotification":   "Duplicate address for this user.",
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
		"UserNameField":            "Name",
		"UserEmailField":           "Email",
		"UserPhoneField":           "Phone",
		"AddressLabelField":        "Label",
		"AddressStreetField":       "Street",
		"AddressNumberField":       "Number",
		"AddressComplementField":   "Complement",
		"AddressNeighborhoodField": "Neighborhood",
		"AddressCityField":         "City",
		"AddressStateField":        "State",
		"AddressZipCodeField":      "ZIP Code",
		"AddressCountryField":      "Country",
	}
}
