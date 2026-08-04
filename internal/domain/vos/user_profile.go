package vos

import "github.com/ClaudioSchirmer/omnicore/domain"

// UserProfile is the User role's access-profile enum value object.
type UserProfile int

// Explicit values (never bare iota): reordering never changes a persisted number.
const (
	UserProfileUnknown  UserProfile = 0 // zero sentinel — never a member
	UserProfileAdmin    UserProfile = 1
	UserProfileManager  UserProfile = 2
	UserProfileOperator UserProfile = 3
	UserProfileClient   UserProfile = 4
	UserProfileSupport  UserProfile = 5
	UserProfileGuest    UserProfile = 6
)

var userProfileMembers = []UserProfile{
	UserProfileAdmin, UserProfileManager, UserProfileOperator,
	UserProfileClient, UserProfileSupport, UserProfileGuest,
}

func (p UserProfile) Value() int            { return int(p) }
func (p UserProfile) Values() []UserProfile { return userProfileMembers }
func (p UserProfile) UnknownNotification() domain.Notification {
	return UnknownUserProfileNotification{}
}
