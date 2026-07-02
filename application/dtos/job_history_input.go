package dtos

import (
	"time"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// JobHistoryInput is the application-layer DTO shared between the Insert
// and Update Employee commands. No JSON tags (wire format lives in
// web/requests/JobHistoryRequest); TerminatedAt is *time.Time on both
// sides (nil = current position).
type JobHistoryInput struct {
	JobTitle     string
	Department   string
	HiredAt      time.Time
	TerminatedAt *time.Time
}

// ToJobHistory materializes an appdomain.JobHistory — a direct copy.
func (h JobHistoryInput) ToJobHistory() appdomain.JobHistory {
	return appdomain.JobHistory{
		JobTitle:     h.JobTitle,
		Department:   h.Department,
		HiredAt:      h.HiredAt,
		TerminatedAt: h.TerminatedAt,
	}
}
