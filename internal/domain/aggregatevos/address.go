package aggregatevos

import (
	"regexp"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/vos"
	"github.com/ClaudioSchirmer/omnicore/domain"
)

// Address is an AggregateValueObject of User. It is persisted in a child table
// linked back to the root by a foreign key — both declared in infra/schema.go
// (AddressSchema) and handled by the framework's aggregate persister; the
// domain itself names no table or column.
//
// Value type (not pointer) so the framework's typed primitives
// (AddAggregateChild / ChangeAggregateChild) track it by value; identity for
// that tracking is declared by IsSameBusinessIdentity below, not by pointer.
//
// Label and Complement are *string because the corresponding columns in
// addresses are nullable. Same convention as User.Phone: nil → NULL.
type Address struct {
	domain.Managed
	Label        *string     `labelKey:"AddressLabelField"`
	Street       string      `labelKey:"AddressStreetField"`
	Number       string      `labelKey:"AddressNumberField"`
	Complement   *string     `labelKey:"AddressComplementField"`
	Neighborhood string      `labelKey:"AddressNeighborhoodField"`
	City         string      `labelKey:"AddressCityField"`
	State        string      `labelKey:"AddressStateField"`
	ZipCode      vos.ZipCode `labelKey:"AddressZipCodeField"`
	Country      string      `labelKey:"AddressCountryField"`

	// AddressType — the child's classification enum (addresses.address_type).
	AddressType vos.AddressType `labelKey:"AddressTypeField"`
}

// IsSameBusinessIdentity is the User's notion of "same address": the same
// real-world place — Country+ZipCode+Street+Number — regardless of
// Label/Complement. It is the framework-required identity that replaced the
// change tracker's former reflect.DeepEqual structural guess, and User.AddAddress
// reuses it as its duplicate rule. Country+ZipCode+Street+Number is a
// country-agnostic shape good enough for the sandbox; production systems would
// normalize whitespace / casing first. A non-Address is never the same.
func (a Address) IsSameBusinessIdentity(other domain.AggregateValueObject) bool {
	o, ok := other.(Address)
	return ok &&
		a.Country == o.Country &&
		a.ZipCode == o.ZipCode &&
		a.Street == o.Street &&
		a.Number == o.Number
}

// The physical columns are declared explicitly in infra/schema.go via
// AddressSchema() (Go field ↔ column, e.g. ZipCode ↔ zip_code); "ID" is the ID
// and the ParentID "user_id" is injected by the persister (it does not belong to the
// struct). The domain never pronounces a column name.

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
		// ZipCode + AddressType are value objects — the framework discovers and
		// validates them off the struct; nothing to wire here.
	})
}

// stateRegex covers two-letter codes ("CA", "NY", "SP"), full names
// ("California", "New York", "Bavaria") and codes with dot/hyphen ("D.C.",
// "Baden-Württemberg" partial). Strict country-specific lists belong in a
// production system, not in this internationalized example.
var stateRegex = regexp.MustCompile(`^[A-Za-z0-9 .\-]{2,50}$`)

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

// CollectionName names the collection this child occupies inside its owner —
// the segment the projection nests it under ("Addresses"), the Go segment a
// filter path walks (?addresses.city → Addresses.City), and, lower-camelled, the
// notification wire path ("addresses[0].zipCode"). Declared, never derived: the
// framework applies no pluralization rule, so a domain that speaks Portuguese
// declares "Enderecos" here and everything downstream follows.
func (Address) CollectionName() string { return "Addresses" }
