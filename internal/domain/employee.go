package domain

import (
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/aggregatevos"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/vos"
	"github.com/ClaudioSchirmer/omnicore/domain"
)

// Employee is the SECOND role over the shared Person identity (the first is
// User). Its purpose in this sandbox is to exercise the framework paths a
// single role cannot: two roles sharing one persons row (refcount + base
// reuse), role-owned children (Dependent, JobHistory) alongside the
// base-owned Address, and a sibling at the child level (Dependent's health
// plan). The entity stays FLAT — infra/schema.go partitions the fields across
// persons / employees / employee_bank_accounts and the child tables.
type Employee struct {
	domain.AggregateRoot

	// ─── Shared Person identity (partitioned into the persons SharedBase) ──
	// Same fields, labels and semantics as User: Document is the immutable
	// natural key deriving the deterministic person id (UUIDv5(document)).
	Name      vos.Name      `labelKey:"UserNameField"`
	Email     vos.Email     `labelKey:"UserEmailField"`
	Phone     *vos.Phone    `labelKey:"UserPhoneField"`
	Document  vos.Document  `labelKey:"UserDocumentField"`
	Ethnicity vos.Ethnicity `labelKey:"PersonEthnicityField"` // shared Person enum

	// ─── Role-private field (employees table) ────────────────────────────
	EmployeeNumber string `labelKey:"EmployeeNumberField"`

	// ─── Role sibling: bank account (employee_bank_accounts, 1:1) ──────
	// *string so a genuinely nil facet means "no sibling row": the framework
	// materializes the row only when at least one field is non-nil (skipped on
	// INSERT, untouched on PATCH, removed by a PUT clearing all four).
	Bank    *string `labelKey:"EmployeeBankField"`
	Branch  *string `labelKey:"EmployeeBranchField"`
	Account *string `labelKey:"EmployeeAccountField"`
	Pix     *string `labelKey:"EmployeePixField"`

	// ─── Children ───────────────────────────────────────────────────────────
	// No slice fields here: the aggregate's children live in the embedded
	// AggregateRoot's collection (added/replaced through the methods below,
	// read with domain.GetCurrentItemsOf), which is what the write path,
	// loader, outbox and audit consume. The boundary is declared by type in
	// AggregateChildren: Address is the BASE's native child (persons owns it),
	// so it is the same list the User role sees; Dependent and JobHistory are
	// role-owned — private to the Employee, invisible to other roles.
}

// Employee needs no domain.Service for the same reason User doesn't:
// identity uniqueness comes from the SharedBase deterministic id, and a second
// active employee for the same person collides on the role PRIMARY KEY
// (shared-ID: employees.id == persons.id).

// ─── domain.Entity ───────────────────────────────────────────────────────────

func (f *Employee) Modes() []domain.EntityMode {
	return []domain.EntityMode{
		domain.ModeDisplay,
		domain.ModeInsert,
		domain.ModeUpdate,
		domain.ModeDelete,
		domain.ModeArchive,
		domain.ModeUnarchive,
	}
}

// ─── domain.AggregateRootProvider ────────────────────────────────────────────

func (f *Employee) GetAggregateRoot() *domain.AggregateRoot {
	return &f.AggregateRoot
}

// AggregateChildren declares the FULL aggregate boundary — the base-owned
// Address plus the two role-owned types. Which table/ParentID each maps to (and
// which of them belong to the base vs the role) is infra's concern, declared
// in EmployeeSchema()/personBase().
func (f *Employee) AggregateChildren() []domain.AggregateValueObject {
	return []domain.AggregateValueObject{aggregatevos.Address{}, aggregatevos.Dependent{}, aggregatevos.JobHistory{}}
}

// ─── Domain methods ──────────────────────────────────────────────────────────

// AddAddress dedups by business identity with MERGE semantics: on a warm
// upsert (the person already exists — e.g. as a User) the loaded aggregate
// carries the person's existing addresses as Constructor items, and a re-sent
// identical address is silently SKIPPED — the documented shared-base contract
// ("an unchanged base-child is a no-op; the dev merges/dedups in the Cmd's
// ApplyTo"), which keeps the cross-role POST idempotent for known addresses.
// This deliberately differs from User.AddAddress, which REJECTS the duplicate
// with DuplicateAddressNotification — on the User surface the warm path is
// unreachable (a second POST for the same document 409s on the role first),
// so its check only ever guards same-request duplicates; here the warm path
// is the norm. For the reject approach, see User.AddAddress in user.go — the
// two methods are the reference pair for the merge-vs-reject choice the
// manual describes for shared-base children.
func (f *Employee) AddAddress(addr aggregatevos.Address, svc domain.Service) {
	domain.EnsureInitialized(f)
	for _, existing := range domain.GetCurrentItemsOf[aggregatevos.Address](&f.AggregateRoot) {
		if existing.IsSameBusinessIdentity(addr) {
			return
		}
	}
	domain.AddAggregateChild(f, addr)
}

// ReplaceAddresses is the PUT full-replace path for the shared collection.
func (f *Employee) ReplaceAddresses(addrs []aggregatevos.Address) {
	domain.EnsureInitialized(f)
	domain.ReplaceAggregateChildrenOf(f, addrs)
}

// AddDependent attaches a role-owned Dependent. No cross-item invariant
// today — Dependent field validation lives in Dependent.BuildRules and runs
// at the boundary.
func (f *Employee) AddDependent(dep aggregatevos.Dependent) {
	domain.EnsureInitialized(f)
	domain.AddAggregateChild(f, dep)
}

// ReplaceDependents is the PUT full-replace path for the dependents.
func (f *Employee) ReplaceDependents(deps []aggregatevos.Dependent) {
	domain.EnsureInitialized(f)
	domain.ReplaceAggregateChildrenOf(f, deps)
}

// AddJobHistory appends one job-history entry.
func (f *Employee) AddJobHistory(h aggregatevos.JobHistory) {
	domain.EnsureInitialized(f)
	domain.AddAggregateChild(f, h)
}

// ReplaceJobHistories is the PUT full-replace path for the job history.
func (f *Employee) ReplaceJobHistories(hs []aggregatevos.JobHistory) {
	domain.EnsureInitialized(f)
	domain.ReplaceAggregateChildrenOf(f, hs)
}

// ─── Validation rules ────────────────────────────────────────────────────────

func (f *Employee) BuildRules(actionName string, service domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		// The shared Person value-object fields (Name, Document, Email, Ethnicity,
		// Phone) validate AUTOMATICALLY — discovered by type, same rules as User,
		// no registration. Only the role-private non-VO field is checked here.
		if f.EmployeeNumber == "" {
			r.AddNotification("EmployeeNumber", domain.RequiredFieldNotification{})
		}
	})

	r.IfUpdate(func() {
		// Document is the shared identity's immutable natural key — same
		// defense-in-depth rule as User (the update/patch DTOs omit it).
		if old := domain.Old(f); old != nil && old.Document != f.Document {
			r.AddNotification("Document", DocumentCannotChangeNotification{}, f.Document)
		}
	})
}
