package domain

import (
	"regexp"

	"github.com/ClaudioSchirmer/omnicore/domain"
)

// Address is an AggregateValueObject of User. It lives in the addresses table,
// linked back via user_id (handled by the framework's aggregate persister).
//
// Value type (not pointer) so reflect.DeepEqual inside the framework's typed
// primitives (AddAggregateChild / ChangeAggregateChild) compares by field
// equality, not pointer identity.
//
// Label and Complement are *string because the corresponding columns in
// addresses are nullable. Same convention as User.Phone: nil → NULL.
type Address struct {
	ID           string
	Label        *string `label:"AddressLabelField"`
	Street       string  `label:"AddressStreetField"`
	Number       string  `label:"AddressNumberField"`
	Complement   *string `label:"AddressComplementField"`
	Neighborhood string  `label:"AddressNeighborhoodField"`
	City         string  `label:"AddressCityField"`
	State        string  `label:"AddressStateField"`
	ZipCode      string  `label:"AddressZipCodeField"`
	Country      string  `label:"AddressCountryField"`
}

func (a Address) GetID() string { return a.ID }

// sameBusinessIdentity returns true when two addresses point to the same
// real-world place from the user's perspective. Used by User.AddAddress to
// reject duplicates. Country + ZipCode + Street + Number is a country-agnostic
// shape good enough for the sandbox; production systems would normalize
// whitespace / casing first.
func (a Address) sameBusinessIdentity(other Address) bool {
	return a.Country == other.Country &&
		a.ZipCode == other.ZipCode &&
		a.Street == other.Street &&
		a.Number == other.Number
}

// Framework infra extracts columns via reflection on the exported fields;
// "ID" and tag `transient:"-"` are skipped automatically; FK "user_id" is
// injected by infra (it does not belong to the struct).

// BuildRules has the same shape as User.BuildRules so root and child read the
// same way: r.IfInsertOrUpdate dispatches by mode, r.AddNotification emits
// using a Go identifier that the framework renders to camelCase. The *Rules
// passed in already carries a scoped NotificationContext, so
// r.AddNotification("ZipCode", n) reaches the wire as "addresses[0].zipCode".
// Pass the rejected input as the optional value (e.g. a.ZipCode) to echo it
// back in the response.
//
// Country-agnostic by design: state and zipCode are validated by shape only
// (no per-country lookup tables). Country is just an ISO 3166-1 alpha-2 shape
// check. Service-specific rules (e.g. "this country requires postal code") are
// out of scope for an international sandbox.
func (a Address) BuildRules(actionName string, service domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if a.Street == "" {
			r.AddNotification("Street", domain.RequiredFieldNotification{})
		}
		if a.Number == "" {
			r.AddNotification("Number", domain.RequiredFieldNotification{})
		}
		if a.Neighborhood == "" {
			r.AddNotification("Neighborhood", domain.RequiredFieldNotification{})
		}
		if a.City == "" {
			r.AddNotification("City", domain.RequiredFieldNotification{})
		}

		if a.Country == "" {
			r.AddNotification("Country", domain.RequiredFieldNotification{})
		} else if !isAlpha2Country(a.Country) {
			r.AddNotification("Country", InvalidCountryNotification{}, a.Country)
		}

		if a.State == "" {
			r.AddNotification("State", domain.RequiredFieldNotification{})
		} else if !stateRegex.MatchString(a.State) {
			r.AddNotification("State", InvalidStateNotification{}, a.State)
		}

		if a.ZipCode == "" {
			r.AddNotification("ZipCode", domain.RequiredFieldNotification{})
		} else if !zipCodeRegex.MatchString(a.ZipCode) {
			r.AddNotification("ZipCode", InvalidZipCodeNotification{}, a.ZipCode)
		}
	})
}

// stateRegex covers two-letter codes ("CA", "NY", "SP"), full names
// ("California", "New York", "Bavaria") and codes with dot/hyphen ("D.C.",
// "Baden-Württemberg" partial). Strict country-specific lists belong in a
// production system, not in this internationalized example.
var stateRegex = regexp.MustCompile(`^[A-Za-z0-9 .\-]{2,50}$`)

// zipCodeRegex covers postal codes from most ISO countries: US "94103" /
// "94103-1234", UK "SW1A 1AA", Canada "K1A 0B1", Germany "10115", Brazil
// "50000000" / "50000-000". Letters, digits, spaces, and hyphens; 3–12 chars.
var zipCodeRegex = regexp.MustCompile(`^[A-Za-z0-9 \-]{3,12}$`)

// isAlpha2Country: ISO 3166-1 alpha-2 shape — two uppercase letters.
// Not a real list lookup; sufficient for the sandbox.
func isAlpha2Country(c string) bool {
	if len(c) != 2 {
		return false
	}
	for _, r := range c {
		if r < 'A' || r > 'Z' {
			return false
		}
	}
	return true
}
