package domain

import (
	"regexp"

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
	Name  string  `labelKey:"UserNameField"`
	Email string  `labelKey:"UserEmailField"`
	Phone *string `labelKey:"UserPhoneField"`

	// Document is the natural key of the shared Person identity (infra maps it
	// to the persons.document column — see infra/schema.go). It deduplicates
	// the identity and derives its deterministic id, so it is IMMUTABLE once
	// set: enforced below in IfUpdate and, atomically, by the framework's
	// SharedBase write path (UUIDv5(document) = the person PK). It replaces
	// email as the way a user record is located on the manual showcase surface.
	Document string `labelKey:"UserDocumentField"`

	// UserName is the ONLY field private to the user role (infra maps it to the
	// users.user_name column); Name/Email/Phone/Document above are all shared
	// Person identity, partitioned away into the persons SharedBase table.
	UserName string `labelKey:"UserUserNameField"`

	// EmailNotification / SmsNotification are the user's notification
	// preferences, persisted to the user_configurations SIBLING table (1:1,
	// shares the user's primary key). *bool is deliberate: a genuinely nil pair
	// means "no configuration row" — the sibling materializes only when at
	// least one is non-nil (PATCH leaves an absent facet untouched; a PUT
	// clearing both removes the row), exercising the framework's conditional
	// sibling write.
	EmailNotification *bool `labelKey:"UserEmailNotificationField"`
	SmsNotification   *bool `labelKey:"UserSmsNotificationField"`

	// ─── Runtime-only authz fields ────────────────────────────────────────
	//
	// Populated by ArchiveUserCommand.ApplyTo from AppContext.Identity right
	// before GetArchivable runs BuildRules in ModeUpdate with actionName=
	// "GetArchivable". The owner-check is encoded as "the JWT's email claim
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

// nameMaxLength is the User's hard cap on the Name field length — a pure
// domain rule of THIS aggregate, not a configurable per-tenant value. Lives
// in the domain layer alongside the entity it constrains; the application
// layer (commands/handlers) never references it.
//
// Acts as the runtime value the parameterized-notification mechanism
// substitutes into the translated message via the
// NameMaxLengthExceededNotification's `tvar:"maxLength"` field. The framework
// renders {maxLength} → "100" in the catalog string at the wire boundary.
//
// If a future requirement demanded per-tenant variability, the rule would
// migrate from a constant to a domain.Service lookup consulted inside
// BuildRules — same notification type, same wire shape, only the source of
// the value changes. Today the example keeps the rule pure to avoid
// dragging an external configuration dependency through every consumer of
// the User aggregate.
const nameMaxLength = 100

// User needs no domain.Service: identity uniqueness is no longer a domain
// concern. The shared Person identity is deduplicated by its natural key
// (Document) through the framework's SharedBase write path — the deterministic
// id UUIDv5(document) IS the person PK, so a second person with the same
// document collides on the primary key, and a second active role for an
// existing person collides on the role's PRIMARY KEY (shared-PK: the role's id
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
// Opt-in for aggregate-aware persistence. The physical table/column/FK names
// are NOT inferred — they are declared explicitly in infra/schema.go via
// UserSchema()/AddressSchema() (table "users"/"addresses", child FK "user_id").
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
	return []domain.AggregateValueObject{Address{}}
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
// Why the manual sameBusinessIdentity loop? The framework already rejects a
// fully-equal duplicate inside AddAggregateChild (reflect.DeepEqual on the
// whole struct → EntityAlreadyAddedNotification). That covers structural
// equality but not the User's notion of "same address": two Address values
// can differ on Label/Complement and still represent the same physical place
// (Country+ZipCode+Street+Number). DeepEqual sees them as distinct; the
// domain doesn't. Defining "same" is a per-aggregate invariant — Address as
// a value type has no canonical identity, the consuming root does — so the
// check lives here, in the root method, as orthodox DDD prescribes. If
// another aggregate ever consumes Address with a different criterion (e.g.,
// one address per country), its own AddAddress would carry its own rule.
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
func (u *User) AddAddress(addr Address, svc domain.Service) {
	domain.EnsureInitialized(u)
	for _, existing := range domain.GetCurrentItemsOf[Address](&u.AggregateRoot) {
		if existing.sameBusinessIdentity(addr) {
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
func (u *User) ChangeAddress(original, replacement Address) {
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
func (u *User) ChangeAddressByID(addressID string, replacement Address) {
	domain.EnsureInitialized(u)
	for _, addr := range domain.GetCurrentItemsOf[Address](&u.AggregateRoot) {
		if addr.GetID().Value() == addressID {
			replacement.ID = domain.NewID(addressID)
			domain.ChangeAggregateChild(u, addr, replacement)
			return
		}
	}
	u.AddNotification("Address", domain.RecordNotFoundNotification{}, addressID)
}

// RemoveAddress marks an Address as REMOVED. On commit: symmetric cascade
// archives the row in addresses.
func (u *User) RemoveAddress(addr Address) {
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
func (u *User) ReplaceAddresses(addrs []Address) {
	domain.EnsureInitialized(u)
	domain.ReplaceAggregateChildrenOf(u, addrs)
}

// ─── Validation rules ────────────────────────────────────────────────────────

func (u *User) BuildRules(actionName string, service domain.Service, r *domain.Rules) {
	r.IfInsertOrUpdate(func() {
		if u.Name == "" {
			r.AddNotification("Name", domain.RequiredFieldNotification{})
		} else if len(u.Name) > nameMaxLength {
			// Parameterized notification showcase: the limit is a pure
			// domain constant (nameMaxLength); the rejected length surfaces
			// inside the translated message via the `tvar:"maxLength"` tag
			// on NameMaxLengthExceededNotification. Wire value carries the
			// rejected input itself (the consumer-supplied Name), mirroring
			// the InvalidEmail/InvalidPhone shape.
			r.AddNotification("Name", NameMaxLengthExceededNotification{MaxLength: nameMaxLength}, u.Name)
		}

		// Document is the shared identity's natural key — required and
		// format-checked, but NOT uniqueness-checked here: the framework's
		// deterministic id (UUIDv5(document)) makes a duplicate document
		// collide on the person PK, surfacing the 409 atomically. Email is a
		// plain shared Person field now (mutable, last-write-wins across roles)
		// — required + regex, but no longer unique and no longer immutable.
		if u.Document == "" {
			r.AddNotification("Document", domain.RequiredFieldNotification{})
		} else if !documentRegex.MatchString(u.Document) {
			r.AddNotification("Document", InvalidDocumentNotification{}, u.Document)
		}

		// UserName is the role's own field — required.
		if u.UserName == "" {
			r.AddNotification("UserName", domain.RequiredFieldNotification{})
		}

		if u.Email == "" {
			r.AddNotification("Email", domain.RequiredFieldNotification{})
		} else if !emailRegex.MatchString(u.Email) {
			r.AddNotification("Email", InvalidEmailNotification{}, u.Email)
		}

		if u.Phone != nil && *u.Phone != "" && !phoneRegex.MatchString(*u.Phone) {
			r.AddNotification("Phone", InvalidPhoneNotification{}, u.Phone)
		}
	})

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

		// Layer-2 owner-check on Archive: actionName branches the rule so
		// PUT/PATCH (GetUpdatable / GetPartialUpdatable) are NOT affected —
		// only the archive verb. The principal must own the resource (email
		// claim matches the persisted email) OR carry users:admin. Service
		// code may extend the rule to Unarchive/Delete the same way; kept on
		// Archive alone here to keep the showcase narrowly scoped.
		//
		// Tolerant of an empty RequestingPrincipalEmail — under
		// auth.mode=disabled (dev) and inside test fixtures that bypass the
		// AppContext middleware, no principal is attached and the rule
		// degrades to "trust" rather than blocking every archive. Production
		// runs under auth.mode=jwt so the field is always populated.
		//
		// The kernel ArchiveNotAllowedNotification already carries
		// SemanticForbidden → 403 so the rejection lands as the canonical
		// Forbidden envelope without needing a service-specific
		// notification.
		if actionName == "GetArchivable" && u.RequestingPrincipalEmail != "" {
			if u.Email != u.RequestingPrincipalEmail && !u.RequestingPrincipalIsAdmin {
				r.AddNotification("ID", domain.ArchiveNotAllowedNotification{})
			}
		}
	})
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

var (
	emailRegex = regexp.MustCompile(`^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$`)
	phoneRegex = regexp.MustCompile(`^\d{10,15}$`)
	// documentRegex shapes the Person natural key: 3–32 chars of letters,
	// digits, dot or hyphen (e.g. "12345678901", "AB-1029"). Kept permissive —
	// the showcase point is "the natural key is validated like any other
	// field", not a specific national-document format.
	documentRegex = regexp.MustCompile(`^[A-Za-z0-9.\-]{3,32}$`)
)
