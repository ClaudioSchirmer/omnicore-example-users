package schemas

import (
	"github.com/ClaudioSchirmer/omnicore/infra/db/core"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
)

// JobHistorySchema is the SECOND role-owned child — plain (no sibling),
// present so the role dispatches more than one child collection of its own.
func JobHistorySchema() *core.TableSchema {
	return core.NewTableSchema[appdomain.JobHistory]("employee_job_histories").
		PK("id").
		FK("employee_id").
		Field("JobTitle", "job_title").
		Field("Department", "department").
		Field("HiredAt", "hired_at").
		Field("TerminatedAt", "terminated_at").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}
