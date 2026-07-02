package domain

import (
	"time"

	"github.com/ClaudioSchirmer/omnicore/domain"
)

// JobHistory is the SECOND role-owned AggregateValueObject of Employee
// (table employee_job_histories, FK employee_id) — it exists so the
// role carries MORE THAN ONE child collection of its own, exercising the
// multi-child dispatch. Plain child, no sibling.
//
// TerminatedAt is *time.Time: nil = the position is the current one.
type JobHistory struct {
	ID           string
	JobTitle     string     `labelKey:"JobHistoryJobTitleField"`
	Department   string     `labelKey:"JobHistoryDepartmentField"`
	HiredAt      time.Time  `labelKey:"JobHistoryHiredAtField"`
	TerminatedAt *time.Time `labelKey:"JobHistoryTerminatedAtField"`
}

func (h JobHistory) GetID() string { return h.ID }

// BuildRules fires at the boundary via runAggregateValidations, scoped at
// jobHistories[i].
func (h JobHistory) BuildRules(actionName string, service domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if h.JobTitle == "" {
			r.AddNotification("JobTitle", domain.RequiredFieldNotification{})
		}
		if h.Department == "" {
			r.AddNotification("Department", domain.RequiredFieldNotification{})
		}
		if h.HiredAt.IsZero() {
			r.AddNotification("HiredAt", domain.RequiredFieldNotification{})
		}
		if h.TerminatedAt != nil && !h.TerminatedAt.IsZero() && h.TerminatedAt.Before(h.HiredAt) {
			r.AddNotification("TerminatedAt", TerminationBeforeHireNotification{}, h.TerminatedAt)
		}
	})
}
