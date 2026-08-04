package vos

import "github.com/ClaudioSchirmer/omnicore/domain"

// AddressType is the Address child's classification enum, string-backed: the
// value IS the wire/persisted token.
type AddressType string

// String-backed: the token IS the value (no iota to shift). Empty = zero
// sentinel, never a member.
const (
	AddressTypeUnknown     AddressType = ""
	AddressTypeResidential AddressType = "residential"
	AddressTypeCommercial  AddressType = "commercial"
	AddressTypeBilling     AddressType = "billing"
	AddressTypeShipping    AddressType = "shipping"
)

var addressTypeMembers = []AddressType{
	AddressTypeResidential, AddressTypeCommercial, AddressTypeBilling, AddressTypeShipping,
}

func (a AddressType) Value() string         { return string(a) }
func (a AddressType) Values() []AddressType { return addressTypeMembers }
func (a AddressType) UnknownNotification() domain.Notification {
	return UnknownAddressTypeNotification{}
}
