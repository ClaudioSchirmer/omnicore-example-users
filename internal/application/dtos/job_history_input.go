package dtos

import (
	"time"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/aggregatevos"
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

// ToJobHistory materializes an aggregatevos.JobHistory — a direct copy.
func (h JobHistoryInput) ToJobHistory() aggregatevos.JobHistory {
	return aggregatevos.JobHistory{
		JobTitle:     h.JobTitle,
		Department:   h.Department,
		HiredAt:      h.HiredAt,
		TerminatedAt: h.TerminatedAt,
	}
}
