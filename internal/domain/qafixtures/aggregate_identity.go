//go:build qa

package qafixtures

import "github.com/ClaudioSchirmer/omnicore/domain"

// IsSameBusinessIdentity implementations for the qa fixture aggregate children.
// AggregateValueObject requires it as the explicit replacement for the change
// tracker's former reflect.DeepEqual guess; these fixtures carry no natural key
// narrower than their full value, so they delegate to IsSameByBusinessFields.

func (l GadgetKitLine) IsSameBusinessIdentity(other domain.AggregateValueObject) bool {
	return domain.IsSameByBusinessFields(l, other)
}

func (l CatalogLine) IsSameBusinessIdentity(other domain.AggregateValueObject) bool {
	return domain.IsSameByBusinessFields(l, other)
}

func (l AccountLine) IsSameBusinessIdentity(other domain.AggregateValueObject) bool {
	return domain.IsSameByBusinessFields(l, other)
}
