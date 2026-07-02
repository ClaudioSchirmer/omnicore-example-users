package domain

import (
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
	Name     string  `labelKey:"UserNameField"`
	Email    string  `labelKey:"UserEmailField"`
	Phone    *string `labelKey:"UserPhoneField"`
	Document string  `labelKey:"UserDocumentField"`

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
	// Addresses is the BASE's native child collection (persons owns it), so it
	// is the same list the User role sees. Dependents and JobHistories are
	// role-owned: private to the Employee, invisible to other roles.
	Addresses    []Address    // base child (shared across roles)
	Dependents   []Dependent  // role child, carries a sibling (A2b)
	JobHistories []JobHistory // role child
}

// Employee needs no domain.Service for the same reason User doesn't:
// identity uniqueness comes from the SharedBase deterministic id, and a second
// active employee for the same person collides on the role PRIMARY KEY
// (shared-PK: employees.id == persons.id).

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
// Address plus the two role-owned types. Which table/FK each maps to (and
// which of them belong to the base vs the role) is infra's concern, declared
// in EmployeeSchema()/personBase().
func (f *Employee) AggregateChildren() []domain.AggregateValueObject {
	return []domain.AggregateValueObject{Address{}, Dependent{}, JobHistory{}}
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
func (f *Employee) AddAddress(addr Address, svc domain.Service) {
	domain.EnsureInitialized(f)
	for _, existing := range domain.GetCurrentItemsOf[Address](&f.AggregateRoot) {
		if existing.sameBusinessIdentity(addr) {
			return
		}
	}
	domain.AddAggregateChild(f, addr)
}

// ReplaceAddresses is the PUT full-replace path for the shared collection.
func (f *Employee) ReplaceAddresses(addrs []Address) {
	domain.EnsureInitialized(f)
	domain.ReplaceAggregateChildrenOf(f, addrs)
}

// AddDependent attaches a role-owned Dependent. No cross-item invariant
// today — Dependent field validation lives in Dependent.BuildRules and runs
// at the boundary.
func (f *Employee) AddDependent(dep Dependent) {
	domain.EnsureInitialized(f)
	domain.AddAggregateChild(f, dep)
}

// ReplaceDependents is the PUT full-replace path for the dependents.
func (f *Employee) ReplaceDependents(deps []Dependent) {
	domain.EnsureInitialized(f)
	domain.ReplaceAggregateChildrenOf(f, deps)
}

// AddJobHistory appends one job-history entry.
func (f *Employee) AddJobHistory(h JobHistory) {
	domain.EnsureInitialized(f)
	domain.AddAggregateChild(f, h)
}

// ReplaceJobHistories is the PUT full-replace path for the job history.
func (f *Employee) ReplaceJobHistories(hs []JobHistory) {
	domain.EnsureInitialized(f)
	domain.ReplaceAggregateChildrenOf(f, hs)
}

// ─── Validation rules ────────────────────────────────────────────────────────

func (f *Employee) BuildRules(actionName string, service domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		// Shared Person fields — same rules as User.BuildRules, because they
		// land on the same persons row (last-write-wins across roles).
		if f.Name == "" {
			r.AddNotification("Name", domain.RequiredFieldNotification{})
		} else if len(f.Name) > nameMaxLength {
			r.AddNotification("Name", NameMaxLengthExceededNotification{MaxLength: nameMaxLength}, f.Name)
		}

		if f.Document == "" {
			r.AddNotification("Document", domain.RequiredFieldNotification{})
		} else if !documentRegex.MatchString(f.Document) {
			r.AddNotification("Document", InvalidDocumentNotification{}, f.Document)
		}

		if f.Email == "" {
			r.AddNotification("Email", domain.RequiredFieldNotification{})
		} else if !emailRegex.MatchString(f.Email) {
			r.AddNotification("Email", InvalidEmailNotification{}, f.Email)
		}

		if f.Phone != nil && *f.Phone != "" && !phoneRegex.MatchString(*f.Phone) {
			r.AddNotification("Phone", InvalidPhoneNotification{}, f.Phone)
		}

		// Role-private field.
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
