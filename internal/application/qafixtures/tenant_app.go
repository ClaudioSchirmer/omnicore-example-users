//go:build qa

package qafixtures

import (
	"time"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/pipeline"
	fwqueries "github.com/ClaudioSchirmer/omnicore/application/queries"
	fwresults "github.com/ClaudioSchirmer/omnicore/application/results"
	"github.com/ClaudioSchirmer/omnicore/domain"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// Commands + queries for the Tenant fixture. What makes them unusual is
// deliberate: the three bodyless verbs each MUTATE the entity inside ApplyTo,
// in the window between the load and the Get* call. That mutation is the
// control variable for two of the suite's four proofs —
//
//   - domain.Old must NOT see it (the snapshot is taken at the load), and
//   - the relational row MUST see it (archive and unarchive execute the update
//     path, so every field the entity holds at write time is persisted).
//
// A no-op ApplyTo, which is what a normal archive command carries, would make
// both assertions vacuous.
const (
	// The plan values each bodyless verb stamps from ApplyTo. They are
	// deliberately distinct so a suite failure names the verb that leaked.
	PlanSetByArchive   = "plan-by-archive-applyto"
	PlanSetByUnarchive = "plan-by-unarchive-applyto"
	PlanSetByDelete    = "plan-by-delete-applyto"
)

type TenantResult struct {
	ID            domain.ID
	Code          string
	Status        string
	Plan          string
	OldStatusSeen string
	OldPlanSeen   string
}

func tenantResult(t *qadomain.Tenant) TenantResult {
	return TenantResult{
		ID:            *t.GetID(),
		Code:          t.Code,
		Status:        t.Status,
		Plan:          t.Plan,
		OldStatusSeen: t.OldStatusSeen,
		OldPlanSeen:   t.OldPlanSeen,
	}
}

// TenantSeatInput is the application-layer shape of one child seat.
type TenantSeatInput struct {
	Label string
	Seat  int
}

func seatsOf(in []TenantSeatInput) []qadomain.TenantSeat {
	out := make([]qadomain.TenantSeat, 0, len(in))
	for _, s := range in {
		out = append(out, qadomain.TenantSeat{Label: s.Label, Seat: s.Seat})
	}
	return out
}

// ─── write ───────────────────────────────────────────────────────────────────

type InsertTenantCommand struct {
	pipeline.CommandWithBodyBase
	Code   string
	Status string
	Plan   string
	Seats  []TenantSeatInput
}

func (c *InsertTenantCommand) ToEntity(_ *configuration.AppContext) (*qadomain.Tenant, error) {
	t := &qadomain.Tenant{Code: c.Code, Status: c.Status, Plan: c.Plan}
	for _, s := range seatsOf(c.Seats) {
		t.AddSeat(s)
	}
	return t, nil
}

func (c *InsertTenantCommand) FromEntity(_ *configuration.AppContext, t *qadomain.Tenant) (TenantResult, error) {
	return tenantResult(t), nil
}

var _ pipeline.InsertCommand[*qadomain.Tenant, TenantResult] = (*InsertTenantCommand)(nil)

// UpdateTenantCommand is the full-body PUT. Sending status "closing" is what
// asks the domain to finish the write as an archive.
type UpdateTenantCommand struct {
	pipeline.CommandWithBodyIDBase
	Code   string
	Status string
	Plan   string
}

func (c *UpdateTenantCommand) ApplyTo(_ *configuration.AppContext, t *qadomain.Tenant) error {
	t.Code = c.Code
	t.Status = c.Status
	t.Plan = c.Plan
	return nil
}

func (c *UpdateTenantCommand) FromEntity(_ *configuration.AppContext, t *qadomain.Tenant) (TenantResult, error) {
	return tenantResult(t), nil
}

// ArchiveTenantCommand carries no body, but its ApplyTo still runs — and it
// changes a field. See the file header: this is the control variable.
type ArchiveTenantCommand struct{ pipeline.CommandByIDBase }

func (*ArchiveTenantCommand) ApplyTo(_ *configuration.AppContext, t *qadomain.Tenant) error {
	t.Plan = PlanSetByArchive
	return nil
}
func (*ArchiveTenantCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.Tenant) (fwresults.None, error) {
	return fwresults.None{}, nil
}

type UnarchiveTenantCommand struct{ pipeline.CommandByIDBase }

func (*UnarchiveTenantCommand) ApplyTo(_ *configuration.AppContext, t *qadomain.Tenant) error {
	t.Plan = PlanSetByUnarchive
	return nil
}
func (*UnarchiveTenantCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.Tenant) (fwresults.None, error) {
	return fwresults.None{}, nil
}

// DeleteTenantCommand mutates too. Nothing survives in the row, so the probe
// here is the audit event: its kind=snapshot payload is built from the OLD
// state and must therefore describe the tenant as it was loaded, never as this
// ApplyTo left it.
type DeleteTenantCommand struct{ pipeline.CommandByIDBase }

func (*DeleteTenantCommand) ApplyTo(_ *configuration.AppContext, t *qadomain.Tenant) error {
	t.Plan = PlanSetByDelete
	return nil
}
func (*DeleteTenantCommand) FromEntity(_ *configuration.AppContext, _ *qadomain.Tenant) (fwresults.None, error) {
	return fwresults.None{}, nil
}

// ─── read ────────────────────────────────────────────────────────────────────

type TenantSeatResult struct {
	ID        *string
	Label     *string
	Seat      *int
	DeletedAt *time.Time
}

// FindTenantsResult mirrors the projected document: the flat tenant plus its
// TenantSeats child array. The probe columns are part of the read shape on
// purpose — the suite asserts the projection and the relational row agree on
// them field for field.
type FindTenantsResult struct {
	ID            *string
	Code          *string
	Status        *string
	Plan          *string
	OldStatusSeen *string
	OldPlanSeen   *string
	DeletedAt     *time.Time
	TenantSeats   []TenantSeatResult
}

type FindTenantsQuery struct {
	fwqueries.QueryWithParamsBase
	Criteria fwqueries.ReadCriteria
}

func (q FindTenantsQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}
func (q FindTenantsQuery) FromQueryResult(_ *configuration.AppContext, r FindTenantsResult) (FindTenantsResult, error) {
	return r, nil
}

type FindTenantByIDQuery struct {
	fwqueries.QueryByIDBase
	Criteria fwqueries.ReadCriteria
}

func (q FindTenantByIDQuery) ToCriteria(_ *configuration.AppContext) (fwqueries.ReadCriteria, error) {
	return q.Criteria, nil
}
func (q FindTenantByIDQuery) FromQueryResult(_ *configuration.AppContext, r FindTenantsResult) (FindTenantsResult, error) {
	return r, nil
}
func (q FindTenantByIDQuery) ContextName() string { return "Tenant" }
