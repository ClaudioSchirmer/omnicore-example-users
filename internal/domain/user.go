package domain

import (
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/aggregatevos"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/vos"
	"github.com/ClaudioSchirmer/omnicore/domain"
)

// User is the aggregate root for this example service.
// Embeds domain.AggregateRoot (which embeds BaseEntity).
//
// Phone is *string because the users.phone column is nullable. Convention:
// nil → NULL in the DB; *"" also becomes NULL (the handler/command normalizes
// empty to nil at the boundary). This form fits directly with the
// AggregateLoader auto-scan: it populates *string from NULL as nil with no
// extra conversion, on any backend.
type User struct {
	domain.AggregateRoot
	// labelKey:"..." declares the catalog key for the human-readable name of each
	// field. The framework's Rules.AddNotification reads the tag at emit time
	// via reflection and stamps MessageDTO.FieldLabel (rendered in the actor's
	// locale) on every notification; the audit pipeline writes the catalog key
	// on FieldChange.FieldLabelKey for render-at-read by future audit readers.
	// Fields without a label tag stay invisible to the label surface — wire
	// `fieldLabel` and audit `fieldLabelKey` are omitempty.
	Name  vos.Name   `labelKey:"UserNameField"`
	Email vos.Email  `labelKey:"UserEmailField"`
	Phone *vos.Phone `labelKey:"UserPhoneField"`

	// Ethnicity — shared Person enum value object (persons.ethnicity); appears
	// on every role over the identity.
	Ethnicity vos.Ethnicity `labelKey:"PersonEthnicityField"`

	// Document is the natural key of the shared Person identity (infra maps it
	// to the persons.document column — see infra/schema.go). It deduplicates
	// the identity and derives its deterministic id, so it is IMMUTABLE once
	// set: enforced below in IfUpdate and, atomically, by the framework's
	// SharedBase write path (UUIDv5(document) = the person ID). It replaces
	// email as the way a user record is located on the manual showcase surface.
	Document vos.Document `labelKey:"UserDocumentField"`

	// UserName is the ONLY field private to the user role (infra maps it to the
	// users.user_name column); Name/Email/Phone/Document above are all shared
	// Person identity, partitioned away into the persons SharedBase table.
	UserName vos.Name `labelKey:"UserUserNameField"`

	// UserProfile — the User role's access-profile enum (users.user_profile).
	UserProfile vos.UserProfile `labelKey:"UserProfileField"`

	// EmailNotification / SmsNotification are the user's notification
	// preferences, persisted to the user_configurations SIBLING table (1:1,
	// shares the user's primary key). *bool is deliberate: a genuinely nil pair
	// means "no configuration row" — the sibling materializes only when at
	// least one is non-nil (PATCH leaves an absent facet untouched; a PUT
	// clearing both removes the row), exercising the framework's conditional
	// sibling write.
	EmailNotification *bool `labelKey:"UserEmailNotificationField"`
	SmsNotification   *bool `labelKey:"UserSmsNotificationField"`

	// Sibling VO + enum (user_configurations, 1:1): both nullable — the sibling
	// row materializes conditionally, so they validate only when present.
	NotificationEmail     *vos.Email                 `labelKey:"UserNotificationEmailField"`
	NotificationFrequency *vos.NotificationFrequency `labelKey:"UserNotificationFrequencyField"`

	// ─── Runtime-only authz fields ────────────────────────────────────────
	//
	// Populated by ArchiveUserCommand.ApplyTo from AppContext.Identity right
	// before GetArchivable runs BuildRules in ModeArchive, where the IfArchive
	// clause reads them. The owner-check is encoded as "the JWT's email claim
	// must match this User's persisted email, unless the principal holds
	// users:admin".
	//
	// No tag is needed: the explicit UserSchema() (infra/schema.go) simply does
	// not declare these fields, so the framework never persists, scans, or
	// audits them — table users has no owner_email column; the principal IS the
	// owner indicator. An undeclared exported field is runtime-only by
	// construction.
	//
	// Living on the root keeps the rule expressible without the framework
	// shipping an entity-vs-identity bridge — same shape services would adopt
	// for any per-resource Layer 2 invariant.
	RequestingPrincipalEmail   string
	RequestingPrincipalIsAdmin bool
}

// User needs no domain.Service: identity uniqueness is no longer a domain
// concern. The shared Person identity is deduplicated by its natural key
// (Document) through the framework's SharedBase write path — the deterministic
// id UUIDv5(document) IS the person ID, so a second person with the same
// document collides on the primary key, and a second active role for an
// existing person collides on the role's PRIMARY KEY (shared-ID: the role's id
// IS the person id). Both surface as a
// 409 from infra. RequiresService therefore stays at its promoted default
// (false), and BuildRules ignores the (nil) service argument.

// ─── domain.Entity ───────────────────────────────────────────────────────────

func (u *User) Modes() []domain.EntityMode {
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
//
// Opt-in for aggregate-aware persistence. The physical table/column/ParentID names
// are NOT inferred — they are declared explicitly in infra/schema.go via
// UserSchema()/AddressSchema() (table "users"/"addresses", child ParentID "user_id").
// The domain stays DDD-pure: it never pronounces a table or column. Cascade
// root↔children is symmetric and universal — no per-child flag.
//
// AggregateChildren declares that Address belongs to this aggregate. The
// framework's typed primitives (AddAggregateChild, ChangeAggregateChild,
// RemoveAggregateChild, ReplaceAggregateChildrenOf) consult this list and
// reject VOs of undeclared types. Address mutations go through the
// AddAddress/ChangeAddress/RemoveAddress/ReplaceAddresses methods below —
// commands no longer talk to primitives directly. This restores to the root
// the authority over the aggregate boundary (orthodox DDD).

func (u *User) GetAggregateRoot() *domain.AggregateRoot {
	return &u.AggregateRoot
}

func (u *User) AggregateChildren() []domain.AggregateValueObject {
	return []domain.AggregateValueObject{aggregatevos.Address{}}
}

// ─── Domain methods (Phase 20) ───────────────────────────────────────────────
//
// Address mutations live here — domain vocabulary, not framework jargon. Each
// method applies invariants spanning children that only the root can know
// (e.g., duplicates across all active addresses) and delegates to the
// framework's top-level primitives (AddAggregateChild & co.) which apply the
// type-guard and mutate the internal collection.
//
// Validation of Address's own fields (Street, ZipCode, Country, …) remains in
// Address.BuildRules and fires at the boundary
// (GetInsertable/GetUpdatable/GetDeletable) via runAggregateValidations —
// same lifecycle as User.BuildRules. Anyone who wants inline feedback can use
// domain.ValidateAggregateChild inside these methods (opt-in; pitfall: if
// the item also enters the collection, the boundary runs BuildRules again
// and produces a duplicated notification).

// AddAddress attaches an Address to the aggregate after checking root
// invariants — today only business-identity duplicate inside the aggregate
// itself; a future UserService could come in as a dependency for external
// lookups (e.g., "is this ZIP already used by another user?").
//
// Why the manual loop? The framework now rejects a same-identity duplicate
// inside AddAggregateChild itself — via Address.IsSameBusinessIdentity, the very
// same Country+ZipCode+Street+Number rule — but with a generic
// EntityAlreadyAddedNotification. This loop runs first so the User answers with
// its own, domain-specific DuplicateAddressNotification instead, and it leaves
// room for a future UserService-backed cross-aggregate rule (e.g. "is this ZIP
// already used by another user?"). Defining "same" is the aggregate's call —
// which is exactly why Address.IsSameBusinessIdentity, not a framework guess,
// now decides it.
//
// EnsureInitialized is the first call — without it, AddNotification before
// the boundary (GetInsertable) would be silently a no-op because the
// NotificationContext does not yet exist on the freshly constructed entity.
//
// Dedup approach: REJECT with a notification. On this surface the duplicate
// can only come from the SAME request body (a warm re-POST of the document
// 409s on the role before any address is examined), so a duplicate here is a
// malformed request and a 422 is the honest answer. For the OTHER approach —
// silent MERGE, which keeps a warm cross-role POST idempotent when the person
// already owns the re-sent address — see Employee.AddAddress in employee.go.
func (u *User) AddAddress(addr aggregatevos.Address, svc domain.Service) {
	domain.EnsureInitialized(u)
	for _, existing := range domain.GetCurrentItemsOf[aggregatevos.Address](&u.AggregateRoot) {
		if existing.IsSameBusinessIdentity(addr) {
			u.AddNotification("Address", DuplicateAddressNotification{})
			return
		}
	}
	domain.AddAggregateChild(u, addr)
}

// ChangeAddress replaces one Address with another (status CHANGED) preserving
// the position in the collection. Useful for edits that do not destroy the
// identity of the row in the DB — the persister infers the ID from the
// exported field and emits UPDATE.
func (u *User) ChangeAddress(original, replacement aggregatevos.Address) {
	domain.EnsureInitialized(u)
	domain.ChangeAggregateChild(u, original, replacement)
}

// ChangeAddressByID is the addressed-by-id variant of ChangeAddress, used by
// the canonical PUT /users/:id/addresses/:addressId surface and its custom
// twin. Looks up the slot whose Address.ID matches addressID, copies the new
// values onto a replacement preserving the same ID, and delegates to
// ChangeAddress. When the ID is absent from the aggregate, surfaces a
// RecordNotFoundNotification on the root (kernel `SemanticNotFound → 404`).
//
// The replacement argument carries only the new field values — its own ID
// field is ignored; this method always pins the replacement's ID to the
// looked-up slot's ID so the framework's auditor pairs pre/post by GetID()
// and the persister emits UPDATE (not INSERT) on the addresses row.
func (u *User) ChangeAddressByID(addressID string, replacement aggregatevos.Address) {
	domain.EnsureInitialized(u)
	for _, addr := range domain.GetCurrentItemsOf[aggregatevos.Address](&u.AggregateRoot) {
		if addr.GetID().Value() == addressID {
			replacement.SetID(domain.NewID(addressID))
			domain.ChangeAggregateChild(u, addr, replacement)
			return
		}
	}
	u.AddNotification("Address", domain.RecordNotFoundNotification{}, addressID)
}

// RemoveAddress marks an Address as REMOVED. On commit: symmetric cascade
// archives the row in addresses.
func (u *User) RemoveAddress(addr aggregatevos.Address) {
	domain.EnsureInitialized(u)
	domain.RemoveAggregateChild(u, addr)
}

// ReplaceAddresses clears the entire current collection and re-adds from the
// new list. Each item goes through the same AddAggregateChild type-guard via
// ReplaceAggregateChildrenOf. PUT (full-replace) uses this path.
//
// Phase 20: does not run a duplicate check between the items in the list — we
// assume the command already sanitized the input (a request shape carrying
// duplicates is a client error, not User's). If you want a stronger rule,
// move the duplicate-check loop here.
func (u *User) ReplaceAddresses(addrs []aggregatevos.Address) {
	domain.EnsureInitialized(u)
	domain.ReplaceAggregateChildrenOf(u, addrs)
}

// ─── Validation rules ────────────────────────────────────────────────────────

func (u *User) BuildRules(actionName string, service domain.Service, r *domain.Rules) {
	// Every value-object field (Name, Document, Email, UserName, Ethnicity,
	// UserProfile, and the nullable Phone / NotificationEmail / NotificationFrequency)
	// validates AUTOMATICALLY — the framework discovers VO-typed fields and runs
	// each one's rule; a nil pointer is skipped. No registration here. Document's
	// FORMAT is part of that; its immutability stays in IfUpdate below.

	// Transition-aware invariant: email is immutable once the user is created.
	// Showcases the framework's domain.Old[T] helper — the Get* path snapshots
	// the loaded entity BEFORE applying the command's mutation, so old.Email
	// holds the pre-mutation value. Same rule fires on PUT (UpdateCommand)
	// and PATCH (PatchUserCommand) because both reach this BuildRules via
	// the framework's Update path.
	//
	// Defense in depth: we still check old != nil even though IfUpdate would
	// only fire in ModeUpdate (where the snapshot is always populated by the
	// framework). Keeps the rule resilient to custom flows that hydrate the
	// entity outside the standard loader path.
	r.IfUpdate(func() {
		// Document is the shared identity's immutable natural key. Showcases
		// domain.Old[T]: the Get* path snapshots the loaded entity BEFORE the
		// command's mutation, so old.Document holds the pre-mutation value.
		// Defense in depth — the framework's SharedBase write path also refuses
		// to re-key the identity; this gives a clean 422 in the happy path.
		// (The update/patch DTOs omit Document entirely, so this normally never
		// fires — it guards custom flows that try to send it.)
		if old := domain.Old(u); old != nil && old.Document != u.Document {
			r.AddNotification("Document", DocumentCannotChangeNotification{}, u.Document)
		}
	})

	// Layer-2 owner-check on Archive: the archive verb dispatches its own
	// IfArchive clause, so PUT/PATCH (IfUpdate) are structurally unaffected —
	// no actionName string branch. The principal must own the resource (email
	// claim matches the persisted email) OR carry users:admin. Service code
	// may add a symmetric IfUnarchive rule the same way; kept on Archive alone
	// here to keep the showcase narrowly scoped.
	//
	// Tolerant of an empty RequestingPrincipalEmail — under auth.mode=disabled
	// (dev) and inside test fixtures that bypass the AppContext middleware, no
	// principal is attached and the rule degrades to "trust" rather than
	// blocking every archive. Production runs under auth.mode=jwt so the field
	// is always populated.
	//
	// The kernel ArchiveNotAllowedNotification already carries
	// SemanticForbidden → 403 so the rejection lands as the canonical Forbidden
	// envelope without needing a service-specific notification.
	r.IfArchive(func() {
		if u.RequestingPrincipalEmail != "" &&
			u.Email.Value() != u.RequestingPrincipalEmail && !u.RequestingPrincipalIsAdmin {
			r.AddNotification("ID", domain.ArchiveNotAllowedNotification{})
		}
	})
}
