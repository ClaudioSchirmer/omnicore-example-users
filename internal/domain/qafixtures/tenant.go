//go:build qa

package qafixtures

import "github.com/ClaudioSchirmer/omnicore/domain"

// Tenant is the QA-only aggregate behind the `old_state_archive` suite. It is
// purpose-built so that four framework guarantees become observable from
// OUTSIDE the process — in a SQL column or in an audit row — rather than only
// in a Go unit test:
//
//  1. domain.Old is captured when the entity is BORN (the load), not when the
//     Get* verb runs. Every rule below copies the old value it sees into a
//     persisted probe column (OldStatusSeen / OldPlanSeen), and every command
//     MUTATES the entity between the load and the verb. If the snapshot were
//     taken late, the probe would hold the mutated value; because it is taken
//     at birth, it holds the loaded one. The difference is a plain SELECT.
//
//  2. An IfUpdate rule can finish the write as an archive (CompleteAsArchive).
//     Status "closing" is the trigger.
//
//  3. A domain rule OR a command's ApplyTo may change any field during archive
//     and unarchive, and that change reaches the relational row — the two verbs
//     now execute the update path instead of writing a lone deleted_at column.
//     IfArchive forces Status to suspended (the archived tenant is a suspended
//     tenant); IfUnarchive restores it to active.
//
//  4. The child cascade still archives and restores TenantSeat rows around
//     that, without touching their business fields.
//
// Everything is gated behind the `qa` build tag, so the canonical binary never
// compiles it.
type Tenant struct {
	domain.AggregateRoot
	Code   string
	Status string
	Plan   string

	// OldStatusSeen / OldPlanSeen are the old-state probes. They are ordinary
	// persisted columns whose ONLY writer is a BuildRules closure reading
	// domain.Old — the suite asserts on them with SQL.
	OldStatusSeen string
	OldPlanSeen   string
}

// The closed status set. "closing" is not a resting state: it is the sentinel
// that asks IfUpdate to finish the write as an archive, so a stored row never
// holds it.
const (
	TenantStatusTrial     = "trial"
	TenantStatusActive    = "active"
	TenantStatusSuspended = "suspended"
	TenantStatusClosing   = "closing"
)

// TenantNoOldState is what the probe columns hold when there is no old state to
// report (an insert), or when the old value itself was empty. A NON-EMPTY
// sentinel is deliberate and portable: Oracle stores the empty string AS NULL,
// so a plain "" in a non-pointer Go string field writes fine and then fails to
// scan on the next load ("converting NULL to string is unsupported"). The other
// three dialects round-trip "" happily — which is exactly what makes this the
// kind of divergence only a four-lane run catches.
const TenantNoOldState = "none"

var tenantStatuses = map[string]struct{}{
	TenantStatusTrial:     {},
	TenantStatusActive:    {},
	TenantStatusSuspended: {},
	TenantStatusClosing:   {},
}

// Modes advertises all five state-changing verbs plus display; DeletedAt on the
// schema pairs with ModeArchive/ModeUnarchive, and ModeArchive is also what
// makes CompleteAsArchive legal.
func (t *Tenant) Modes() []domain.EntityMode {
	return []domain.EntityMode{
		domain.ModeDisplay,
		domain.ModeInsert,
		domain.ModeUpdate,
		domain.ModeDelete,
		domain.ModeArchive,
		domain.ModeUnarchive,
	}
}

func (t *Tenant) GetAggregateRoot() *domain.AggregateRoot { return &t.AggregateRoot }

func (t *Tenant) AggregateChildren() []domain.AggregateValueObject {
	return []domain.AggregateValueObject{TenantSeat{}}
}

func (t *Tenant) AddSeat(s TenantSeat) { domain.AddAggregateChild(t, s) }

// recordOld copies what domain.Old exposes at THIS point in the write into the
// two probe columns. Called from every verb that has an old state. The nil
// guard keeps the rule usable from a custom flow that hydrates the entity
// outside the framework's loader.
func (t *Tenant) recordOld() {
	if old := domain.Old(t); old != nil {
		t.OldStatusSeen = orNoOldState(old.Status)
		t.OldPlanSeen = orNoOldState(old.Plan)
	}
}

func orNoOldState(v string) string {
	if v == "" {
		return TenantNoOldState
	}
	return v
}

func (t *Tenant) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if t.Code == "" {
			r.AddNotification("Code", domain.RequiredFieldNotification{})
		}
		if _, ok := tenantStatuses[t.Status]; !ok {
			r.AddNotification("Status", domain.SchemaViolationNotification{}, t.Status)
		}
	})

	// An insert has no old state; say so explicitly rather than leaving the
	// probe columns empty (see TenantNoOldState).
	r.IfInsert(func() {
		t.OldStatusSeen = TenantNoOldState
		t.OldPlanSeen = TenantNoOldState
	})

	r.IfUpdate(func() {
		t.recordOld()
		// The domain — not the caller, not the transport — decides that a
		// tenant moving to "closing" is really being archived. The framework
		// then runs the whole archive: deleted_at, the child cascade, the
		// ARCHIVED outbox event, the archive audit entry.
		//
		// IfArchive does NOT fire on this path (CompleteAsArchive does not
		// re-run the rules in ModeArchive), so the status this closure leaves
		// behind is the one that gets persisted. That is why it sets the
		// resting status here instead of relying on the archive rule.
		if t.Status == TenantStatusClosing {
			t.Status = TenantStatusSuspended
			t.CompleteAsArchive()
		}
	})

	r.IfArchive(func() {
		t.recordOld()
		// The bug this suite exists to keep dead: before archive executed the
		// update path, this assignment reached the CDC payload (and therefore
		// Mongo) but never the relational row.
		t.Status = TenantStatusSuspended
	})

	r.IfUnarchive(func() {
		t.recordOld()
		t.Status = TenantStatusActive
	})

	r.IfDelete(func() {
		// Nothing to persist — the row is going away. The probe for delete is
		// the audit event, whose kind=snapshot payload is built FROM the old
		// state, so it must describe the row as loaded and not as the command
		// left it.
		t.recordOld()
	})
}

// TenantSeat is the native child (qa_tenant_seats). Its business fields exist
// to prove what an archive must NOT do: Label and Seat have to survive the
// cascade untouched, with only deleted_at moving.
type TenantSeat struct {
	domain.Managed
	Label string
	Seat  int
}

func (s TenantSeat) BuildRules(_ string, _ domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if s.Label == "" {
			r.AddNotification("Label", domain.RequiredFieldNotification{})
		}
	})
}
