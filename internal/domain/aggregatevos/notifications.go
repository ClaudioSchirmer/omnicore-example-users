package aggregatevos

import "github.com/ClaudioSchirmer/omnicore/domain"

// Notifications emitted by the aggregate value objects in this package. Each
// embeds DomainNotificationBase, so reflect.TypeOf(...).Name() is its
// translation key (e.g. "InvalidStateNotification"). Default Semantic is
// Validation → 422; the wire value echoes the rejected input.

// InvalidStateNotification / InvalidCountryNotification are emitted by
// Address.BuildRules when the state or country fails its shape check.
type InvalidStateNotification struct{ domain.DomainNotificationBase }
type InvalidCountryNotification struct{ domain.DomainNotificationBase }

// TerminationBeforeHireNotification is emitted by JobHistory.BuildRules when a
// job-history entry ends before it starts.
type TerminationBeforeHireNotification struct{ domain.DomainNotificationBase }
