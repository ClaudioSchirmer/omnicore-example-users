package domain_test

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/domain"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// validateUserWithAddress hydrates a valid User + 1 Address (which overrides
// validAddress() from user_test.go) and runs IsValid. Errors surface under
// "addresses[0].<field>" because runAggregateValidations scopes the ctx by the
// inferred table name for Address ("addresses") + index 0.
//
// User needs no domain service, so we pass nil. The root carries valid
// Person/role fields (validUser) so the only notifications that can surface are
// the address's own — keeping these assertions scoped to Address.BuildRules.
func validateUserWithAddress(addr appdomain.Address) []*domain.NotificationContext {
	u := validUser()
	u.AddAddress(addr, nil)
	_, ctxs := domain.IsValid(u, domain.ModeInsert, nil)
	return ctxs
}

func TestAddress_BuildRules_HappyPathInternational(t *testing.T) {
	// Exercise multiple country shapes to prove the rules are country-agnostic.
	cases := []appdomain.Address{
		{Street: "Main", Number: "100", Neighborhood: "Downtown", City: "San Francisco",
			State: "CA", ZipCode: "94103", Country: "US"},
		{Street: "Main", Number: "100", Neighborhood: "Downtown", City: "San Francisco",
			State: "California", ZipCode: "94103-1234", Country: "US"},
		{Street: "10 Downing", Number: "10", Neighborhood: "Westminster", City: "London",
			State: "England", ZipCode: "SW1A 1AA", Country: "GB"},
		{Street: "Sussex Dr", Number: "24", Neighborhood: "Ottawa", City: "Ottawa",
			State: "ON", ZipCode: "K1A 0B1", Country: "CA"},
		{Street: "Unter den Linden", Number: "1", Neighborhood: "Mitte", City: "Berlin",
			State: "Berlin", ZipCode: "10117", Country: "DE"},
		{Street: "Rua das Flores", Number: "100", Neighborhood: "Centro", City: "Recife",
			State: "PE", ZipCode: "50000-000", Country: "BR"},
	}
	for _, addr := range cases {
		t.Run(addr.Country+"_"+addr.ZipCode, func(t *testing.T) {
			ctxs := validateUserWithAddress(addr)
			if len(ctxs) > 0 && hasAnyError(ctxs) {
				t.Fatalf("expected no errors for %+v; got %s", addr, dumpContexts(ctxs))
			}
		})
	}
}

func TestAddress_BuildRules_RequiredFields(t *testing.T) {
	cases := []struct {
		field    string // resolved wire field expected
		mutate   func(*appdomain.Address)
		notifKey string
	}{
		{"addresses[0].street", func(a *appdomain.Address) { a.Street = "" }, "RequiredFieldNotification"},
		{"addresses[0].number", func(a *appdomain.Address) { a.Number = "" }, "RequiredFieldNotification"},
		{"addresses[0].neighborhood", func(a *appdomain.Address) { a.Neighborhood = "" }, "RequiredFieldNotification"},
		{"addresses[0].city", func(a *appdomain.Address) { a.City = "" }, "RequiredFieldNotification"},
		{"addresses[0].state", func(a *appdomain.Address) { a.State = "" }, "RequiredFieldNotification"},
		{"addresses[0].zipCode", func(a *appdomain.Address) { a.ZipCode = "" }, "RequiredFieldNotification"},
		{"addresses[0].country", func(a *appdomain.Address) { a.Country = "" }, "RequiredFieldNotification"},
	}
	for _, c := range cases {
		t.Run(c.field, func(t *testing.T) {
			addr := validAddress()
			c.mutate(&addr)
			ctxs := validateUserWithAddress(addr)
			if !hasNotification(ctxs, c.field, c.notifKey) {
				t.Fatalf("expected %s on %s; got %s", c.notifKey, c.field, dumpContexts(ctxs))
			}
		})
	}
}

func TestAddress_BuildRules_StateInvalid(t *testing.T) {
	cases := []string{
		"X",     // too short
		"@",     // forbidden char
		"NY#",   // forbidden char
		"Sao!",  // forbidden punctuation
		"超長字符串", // non-ASCII (regex rejects)
	}
	for _, bad := range cases {
		t.Run(bad, func(t *testing.T) {
			addr := validAddress()
			addr.State = bad
			ctxs := validateUserWithAddress(addr)
			if !hasNotification(ctxs, "addresses[0].state", "InvalidStateNotification") {
				t.Fatalf("expected InvalidStateNotification for state=%q; got %s", bad, dumpContexts(ctxs))
			}
		})
	}
}

func TestAddress_BuildRules_ZipCodeInvalid(t *testing.T) {
	cases := []string{
		"12",              // too short
		"123456789012345", // too long
		"94103!",          // forbidden char
		"abc_def",         // underscore not allowed
	}
	for _, bad := range cases {
		t.Run(bad, func(t *testing.T) {
			addr := validAddress()
			addr.ZipCode = bad
			ctxs := validateUserWithAddress(addr)
			if !hasNotification(ctxs, "addresses[0].zipCode", "InvalidZipCodeNotification") {
				t.Fatalf("expected InvalidZipCodeNotification for zip=%q; got %s", bad, dumpContexts(ctxs))
			}
		})
	}
}

func TestAddress_BuildRules_CountryInvalid(t *testing.T) {
	cases := []string{
		"U",   // one letter
		"USA", // three letters
		"us",  // lowercase
		"U1",  // digit
	}
	for _, bad := range cases {
		t.Run(bad, func(t *testing.T) {
			addr := validAddress()
			addr.Country = bad
			ctxs := validateUserWithAddress(addr)
			if !hasNotification(ctxs, "addresses[0].country", "InvalidCountryNotification") {
				t.Fatalf("expected InvalidCountryNotification for country=%q; got %s", bad, dumpContexts(ctxs))
			}
		})
	}
}

// hasAnyError checks if any context carries any message — used by the
// international happy-path test to detect spurious failures across countries.
func hasAnyError(ctxs []*domain.NotificationContext) bool {
	for _, ctx := range ctxs {
		if len(ctx.Messages()) > 0 {
			return true
		}
	}
	return false
}
