package vos

import "github.com/ClaudioSchirmer/omnicore/domain"

// Ethnicity is a shared Person enum value object (IBGE-style closed set),
// string-backed: the value IS the wire/persisted token. The framework validates
// membership — no hand-written IsValid.
type Ethnicity string

// String-backed: the token IS the value (no iota to shift). Empty = zero
// sentinel, never a member.
const (
	EthnicityUnknown     Ethnicity = ""
	EthnicityWhite       Ethnicity = "white"
	EthnicityBlack       Ethnicity = "black"
	EthnicityAsian       Ethnicity = "asian"
	EthnicityMixed       Ethnicity = "mixed"
	EthnicityIndigenous  Ethnicity = "indigenous"
	EthnicityNotDeclared Ethnicity = "not_declared"
)

var ethnicityMembers = []Ethnicity{
	EthnicityWhite, EthnicityBlack, EthnicityAsian,
	EthnicityMixed, EthnicityIndigenous, EthnicityNotDeclared,
}

func (e Ethnicity) Value() string                            { return string(e) }
func (e Ethnicity) Values() []Ethnicity                      { return ethnicityMembers }
func (e Ethnicity) UnknownNotification() domain.Notification { return UnknownEthnicityNotification{} }
