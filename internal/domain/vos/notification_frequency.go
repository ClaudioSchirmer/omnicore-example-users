package vos

import "github.com/ClaudioSchirmer/omnicore/domain"

// NotificationFrequency is the user-configuration sibling's cadence enum.
type NotificationFrequency int

// Explicit values (never bare iota): reordering never changes a persisted number.
const (
	NotificationFrequencyUnknown   NotificationFrequency = 0 // zero sentinel — never a member
	NotificationFrequencyImmediate NotificationFrequency = 1
	NotificationFrequencyDaily     NotificationFrequency = 2
	NotificationFrequencyWeekly    NotificationFrequency = 3
	NotificationFrequencyNever     NotificationFrequency = 4
)

var notificationFrequencyMembers = []NotificationFrequency{
	NotificationFrequencyImmediate, NotificationFrequencyDaily,
	NotificationFrequencyWeekly, NotificationFrequencyNever,
}

func (f NotificationFrequency) Value() int                      { return int(f) }
func (f NotificationFrequency) Values() []NotificationFrequency { return notificationFrequencyMembers }
func (f NotificationFrequency) UnknownNotification() domain.Notification {
	return UnknownNotificationFrequencyNotification{}
}
