package requests

import (
	"time"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/dtos"
)

// JobHistoryRequest is the wire shape of a JobHistory inside the
// Insert/Update Employee payloads. Shape mirrors dtos.JobHistoryInput
// 1:1 — TerminatedAt nil = current position.
type JobHistoryRequest struct {
	JobTitle     string     `json:"jobTitle"                  example:"Engineer"`
	Department   string     `json:"department"           example:"Platform"`
	HiredAt      time.Time  `json:"hiredAt"               example:"2022-01-10T00:00:00Z"`
	TerminatedAt *time.Time `json:"terminatedAt,omitempty" example:"2024-06-30T00:00:00Z"`
}

// ToJobHistoryInput converts the wire DTO into the application DTO — pure
// assignment.
func (h JobHistoryRequest) ToJobHistoryInput() dtos.JobHistoryInput {
	return dtos.JobHistoryInput{
		JobTitle:     h.JobTitle,
		Department:   h.Department,
		HiredAt:      h.HiredAt,
		TerminatedAt: h.TerminatedAt,
	}
}
