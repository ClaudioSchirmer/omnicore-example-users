package web

import (
	"github.com/ClaudioSchirmer/omnicore/application/handlers"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	fwweb "github.com/ClaudioSchirmer/omnicore/web"
	"github.com/ClaudioSchirmer/omnicore/web/export"
	fwgraphql "github.com/ClaudioSchirmer/omnicore/web/graphql"
	fwopenapi "github.com/ClaudioSchirmer/omnicore/web/openapi"
	fwresponses "github.com/ClaudioSchirmer/omnicore/web/responses"

	"github.com/ClaudioSchirmer/omnicore-example-users/internal/application/commands"
	appqueries "github.com/ClaudioSchirmer/omnicore-example-users/internal/application/queries"
	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/web/requests"

	"github.com/gofiber/fiber/v3"
)

// MountEmployees registers the write + query routes for the Employee
// aggregate — the second role over the shared Person identity. 100% canonical
// surface (auto handlers + openapi.Mount), mirroring MountUsers; there is
// deliberately NO by-id GET (the list's filters cover the lookup) and no
// custom route.
func MountEmployees(
	app *fiber.App,
	repo persistence.ScopedRepository[*appdomain.Employee],
	svc domain.Service,
	view *query.ViewDefinition,
	d bootstrap.Deps,
) {
	employees := app.Group("/employees")
	viewName := view.Name()

	insertH, insertSpec := fwweb.CommandWithBodySpec(d.Pipeline,
		requests.InsertEmployeeRequest{},
		requests.InsertEmployeeResponse{}.FromResult,
		&handlers.SharedBaseInsertCommandHandler[*appdomain.Employee, *commands.InsertEmployeeCommand, commands.InsertEmployeeResult]{
			Repo: repo, Service: svc,
		}, fiber.StatusCreated)
	fwopenapi.Mount(d.OpenAPIRegistry, employees, fiber.MethodPost, "/",
		insertH, insertSpec,
		fwopenapi.Doc{
			Summary:     "Create an employee (employee)",
			Description: "Creates an employee backed by the SAME shared Person identity the User role uses. Because the person is deduplicated by `document`, this POST is an UPSERT: when the person already exists (e.g. created as a User), it gains its employee role — shared fields update last-write-wins, existing addresses are deduped against the request's. Re-POSTing the same document for a person who already has an ACTIVE employee returns 409; an ARCHIVED employee is invisible to the insert (soft-delete is delete) and the shared-PK remnant vetoes the write — the same 409, with `PATCH /employees/:id/unarchive` as the explicit way back. The bank block persists to the `employee_bank_accounts` sibling (row materialized only when at least one field is sent); each dependent's plan block behaves identically one level down (`dependent_health_plans`).",
			Tags:        []string{"Employees"},
		},
		fwopenapi.RequirePermission("employees:write"))

	updateH, updateSpec := fwweb.CommandWithBodyIDSpec(d.Pipeline,
		requests.UpdateEmployeeRequest{},
		requests.UpdateEmployeeResponse{}.FromResult,
		&handlers.UpdateCommandHandler[*appdomain.Employee, *commands.UpdateEmployeeCommand, commands.UpdateEmployeeResult]{
			Repo: repo, Service: svc,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, employees, fiber.MethodPut, "/:id",
		updateH, updateSpec,
		fwopenapi.Doc{
			Summary:     "Replace an employee (full body)",
			Description: "Full replacement, strict body (`FullBody` — every exported field must be present, nullable ones at least as an explicit null). Shared Person fields update last-write-wins on the base; `employeeNumber` updates the role; the three child collections (`addresses`, `dependents`, `jobHistories`) are replaced atomically. Sibling semantics: sending every bank field as null removes the `employee_bank_accounts` row; a dependent sent without its plan fields loses its `dependent_health_plans` row. `document` is the immutable natural key and is not part of the body.",
			Tags:        []string{"Employees"},
		},
		fwopenapi.RequirePermission("employees:write"))

	patchH, patchSpec := fwweb.CommandWithBodyIDSpec(d.Pipeline,
		requests.PatchEmployeeRequest{},
		requests.PatchEmployeeResponse{}.FromResult,
		&handlers.PartialUpdateCommandHandler[*appdomain.Employee, *commands.PatchEmployeeCommand, commands.PatchEmployeeResult]{
			Repo: repo, Service: svc,
		}, fiber.StatusOK)
	fwopenapi.Mount(d.OpenAPIRegistry, employees, fiber.MethodPatch, "/:id",
		patchH, patchSpec,
		fwopenapi.Doc{
			Summary:     "Patch an employee (partial body)",
			Description: "Partial root update — only fields present in the body are applied. Children are NOT patchable (use PUT for atomic collection replacement). Omitting the bank fields leaves the `employee_bank_accounts` sibling untouched; sending any of them upserts the row.",
			Tags:        []string{"Employees"},
		},
		fwopenapi.RequirePermission("employees:write"))

	deleteH, deleteSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.DeleteCommandHandler[*appdomain.Employee, *commands.DeleteEmployeeCommand, fwresults.None]{
			Repo: repo, Service: svc,
		}, fiber.StatusNoContent)
	fwopenapi.Mount(d.OpenAPIRegistry, employees, fiber.MethodDelete, "/:id",
		deleteH, deleteSpec,
		fwopenapi.Doc{
			Summary:     "Hard-delete an employee",
			Description: "Hard delete — irreversible. Removes the employee role row plus its role-owned children (dependents with their plan siblings, job-history) explicitly in Go, same TX; then reference-counts the shared Person. With another role (e.g. the User) still referencing it, the person stays; with none, `OrphanPolicy(DeleteWhenUnreferenced)` purges the person + addresses under a vetoable savepoint (an FK from ANY table — the role FKs are `RESTRICT` — cancels the purge). An actual purge emits its own audit event (`entityType` = `persons`) and its own `DELETED` outbox row alongside the role's.",
			Tags:        []string{"Employees"},
		},
		fwopenapi.RequirePermission("employees:delete"))

	archiveH, archiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.ArchiveCommandHandler[*appdomain.Employee, *commands.ArchiveEmployeeCommand, fwresults.None]{
			Repo: repo, Service: svc,
		}, fiber.StatusNoContent)
	fwopenapi.Mount(d.OpenAPIRegistry, employees, fiber.MethodPatch, "/:id/archive",
		archiveH, archiveSpec,
		fwopenapi.Doc{
			Summary:     "Archive an employee (cascade children)",
			Description: "Soft delete via `deleted_at = NOW()`. Aggregate-aware: the same TX archives every active dependent and job-history entry. The shared Person base converges per role lifecycle — it archives only when the LAST active role of that identity goes (keep-by-default across roles). Symmetric inverse of `/unarchive`.",
			Tags:        []string{"Employees"},
		},
		fwopenapi.RequirePermission("employees:archive"))

	unarchiveH, unarchiveSpec := fwweb.CommandByIDSpec(d.Pipeline,
		fwresponses.NoBody,
		&handlers.UnarchiveCommandHandler[*appdomain.Employee, *commands.UnarchiveEmployeeCommand, fwresults.None]{
			Repo: repo, Service: svc,
		}, fiber.StatusNoContent)
	fwopenapi.Mount(d.OpenAPIRegistry, employees, fiber.MethodPatch, "/:id/unarchive",
		unarchiveH, unarchiveSpec,
		fwopenapi.Doc{
			Summary:     "Unarchive an employee (restore archived children)",
			Description: "Reverses `/archive`. Clears `deleted_at` on the role and on every child archived alongside it; the shared Person base revives with its first active role. Emits `UNARCHIVED`; the SyncEngine re-composes and upserts the Mongo document.",
			Tags:        []string{"Employees"},
		},
		fwopenapi.RequirePermission("employees:archive"))

	listH, listSpec := fwweb.QueryWithParamsSpec(d.Pipeline,
		requests.FindEmployeesByParamsRequest{},
		fwresponses.AutoFromDoc[requests.FindEmployeesByParamsResponse],
		&handlers.FindByParamsQueryHandler[*appqueries.FindEmployeeByParamsQuery]{
			Reader: d.ViewReader, View: viewName,
		})
	fwopenapi.Mount(d.OpenAPIRegistry, employees, fiber.MethodGet, "/",
		listH, listSpec,
		fwopenapi.Doc{
			Summary:     "List employees (paged + filter)",
			Description: "Paged read against the `employees` Mongo view. Filters cover root fields (name/email/document/employeeNumber), the bank sibling (bank), and child paths (`?dependents.relationship=daughter`, `?dependents.healthPlanProvider=…` — a child-SIBLING field — and `?jobHistories.department=…`). Same reserved keys as GET /users (`limit/after/before/sort/fields/search/includeArchived/onlyTotal`). There is no by-id endpoint — filter by `?document=` or `?employeeNumber=` instead.",
			Tags:        []string{"Employees"},
		},
		fwopenapi.RequirePermission("employees:read"))

	// CSV export — same Request DTO and view query handler as GET /employees,
	// rendered hierarchically (root at column A, each child one level in).
	// Registered at the app root to avoid colliding with /employees/:id.
	csvH, csvSpec := fwweb.QueryAsCSVSpec(d.Pipeline,
		requests.FindEmployeesByParamsRequest{},
		view,
		d.Export,
		&handlers.FindByParamsQueryHandler[*appqueries.FindEmployeeByParamsQuery]{
			Reader: d.ViewReader, View: viewName,
		},
		export.WithDelimiter(','))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/employees.csv",
		csvH, csvSpec,
		fwopenapi.Doc{
			Summary:     "Export employees as CSV",
			Description: "Streams the same `employees` view read as GET /employees — same filter allowlist, `?search`, `?sort`, `?includeArchived`, `?fields=` — as a hierarchical CSV: root (with the flat bank sibling) at column A, addresses/dependents/jobHistories one level in; the dependent rows include the flat plan-sibling columns. Headers come from the fields' `labelKey` catalog entries rendered per Accept-Language. Pagination is ignored — the full filtered set streams capped at `query.maxExportRows`.",
			Tags:        []string{"Employees"},
		},
		fwopenapi.RequirePermission("employees:read"))

	// XLSX export — identical surface, different encoder.
	xlsxH, xlsxSpec := fwweb.QueryAsXLSXSpec(d.Pipeline,
		requests.FindEmployeesByParamsRequest{},
		view,
		d.Export,
		&handlers.FindByParamsQueryHandler[*appqueries.FindEmployeeByParamsQuery]{
			Reader: d.ViewReader, View: viewName,
		},
		export.WithSheetName("Employees"))
	fwopenapi.Mount(d.OpenAPIRegistry, app, fiber.MethodGet, "/employees.xlsx",
		xlsxH, xlsxSpec,
		fwopenapi.Doc{
			Summary:     "Export employees as Excel (.xlsx)",
			Description: "Same surface as `GET /employees.csv` — same filter allowlist, `?fields=`, `?search`, `?sort`, `?includeArchived`, same hierarchical layout and labelKey headers — serialized as an Excel workbook.",
			Tags:        []string{"Employees"},
		},
		fwopenapi.RequirePermission("employees:read"))
}

// MountEmployeesGraphQL contributes the Employee aggregate's fields to
// the service's single GraphQL registry — the GraphQL twin of
// MountEmployees, exactly parallel to MountUsersGraphQL. It reuses the
// SAME application handlers the REST surface mounts; each field carries the
// same Layer-1 permission as its REST twin. There is no by-id query — the
// `employees` connection's `where` filter covers the lookup, as on users.
func MountEmployeesGraphQL(
	reg *fwgraphql.Registry,
	repo persistence.ScopedRepository[*appdomain.Employee],
	svc domain.Service,
	view *query.ViewDefinition,
	d bootstrap.Deps,
) {
	reg.Register(fwgraphql.QueryWithParams[
		requests.FindEmployeesByParamsRequest,
		requests.FindEmployeesByParamsResponse,
	](
		"employees", "Employee",
		&handlers.FindByParamsQueryHandler[*appqueries.FindEmployeeByParamsQuery]{
			Reader: d.ViewReader, View: view.Name(),
		},
		fwgraphql.RequirePermission("employees:read")))

	reg.Register(fwgraphql.MutationWithBody[requests.InsertEmployeeRequest](
		"createEmployee", requests.InsertEmployeeResponse{}.FromResult,
		&handlers.SharedBaseInsertCommandHandler[*appdomain.Employee, *commands.InsertEmployeeCommand, commands.InsertEmployeeResult]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("employees:write")))

	reg.Register(fwgraphql.MutationWithBodyID[requests.UpdateEmployeeRequest](
		"updateEmployee", requests.UpdateEmployeeResponse{}.FromResult,
		&handlers.UpdateCommandHandler[*appdomain.Employee, *commands.UpdateEmployeeCommand, commands.UpdateEmployeeResult]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("employees:write")))

	reg.Register(fwgraphql.MutationWithBodyID[requests.PatchEmployeeRequest](
		"patchEmployee", requests.PatchEmployeeResponse{}.FromResult,
		&handlers.PartialUpdateCommandHandler[*appdomain.Employee, *commands.PatchEmployeeCommand, commands.PatchEmployeeResult]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("employees:write")))

	reg.Register(fwgraphql.MutationByID(
		"archiveEmployee",
		&handlers.ArchiveCommandHandler[*appdomain.Employee, *commands.ArchiveEmployeeCommand, fwresults.None]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("employees:archive")))

	reg.Register(fwgraphql.MutationByID(
		"unarchiveEmployee",
		&handlers.UnarchiveCommandHandler[*appdomain.Employee, *commands.UnarchiveEmployeeCommand, fwresults.None]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("employees:archive")))

	reg.Register(fwgraphql.MutationByID(
		"deleteEmployee",
		&handlers.DeleteCommandHandler[*appdomain.Employee, *commands.DeleteEmployeeCommand, fwresults.None]{
			Repo: repo, Service: svc,
		},
		fwgraphql.RequirePermission("employees:delete")))
}
