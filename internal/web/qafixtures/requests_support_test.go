//go:build qa

package qafixtures

// strptr returns a pointer to s — a test helper for building the optional
// pointer fields on the manual-showcase request DTOs. Mirrors the same helper
// in web/requests/address_test.go (a separate package after the qa
// split, so it is redeclared here).
func strptr(s string) *string { return &s }
