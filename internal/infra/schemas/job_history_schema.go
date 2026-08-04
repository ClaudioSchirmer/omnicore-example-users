package schemas

import (
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/aggregatevos"
	"github.com/ClaudioSchirmer/omnicore/infra/db/core"
)

// JobHistorySchema is the SECOND role-owned child — plain (no sibling),
// present so the role dispatches more than one child collection of its own.
func JobHistorySchema() *core.TableSchema {
	return core.NewTableSchema[aggregatevos.JobHistory]("employee_job_histories").
		ID("id").
		ParentID("employee_id").
		Field("JobTitle", "job_title").
		Field("Department", "department").
		Field("HiredAt", "hired_at").
		Field("TerminatedAt", "terminated_at").
		DeletedAt("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}
