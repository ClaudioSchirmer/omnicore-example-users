package infra

import (
	"context"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/read"
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/write"
	"github.com/ClaudioSchirmer/omnicore/infra/db/core"
	"github.com/ClaudioSchirmer/omnicore/infra/db/criteria"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain"
	"github.com/ClaudioSchirmer/omnicore-example-users/internal/infra/schemas"
)

// UserCustomRepository is the manual counterpart to UserRepository, used by
// the /showcase/users-custom/* surface. The canonical UserRepository embeds
// read.BaseAggregateRepository — New() + FindByID + FindArchivedByID +
// Scope come "for free" via promotion. This struct deliberately does NOT
// embed it: the reads + the scoped-write binding are written out so a reader
// can see what the canonical wrapper hides, and so we can add the document-keyed
// lookups (FindByDocument / FindArchivedByDocument) that no framework primitive
// exposes.
//
// The repository PORT (read+write) is a domain concept — appdomain.UserCustomRepository
// in domain/user_custom_repository.go. This struct is the infra adapter that
// satisfies it: reads are direct (no ctx); writes are bound to the request
// *AppContext via Scope, which returns a value satisfying appdomain.UserCustomRepository
// with its Writer half already scoped. The five writes inside the bound writer
// are 1-line delegations to the neutral core.RelationalEngine — the same
// primitives BaseRepository.Scope calls under the hood, on any backend.
//
// FindByDocument and FindArchivedByDocument are the actual reason this
// Repository exists. The /:document path identifier on the showcase routes is
// an alternate key the by-id contract does not cover; the custom Repository
// resolves it through the framework's entity search engine —
// criteria.Eq("Document", document) handed to the AggregateLoader's FindOne,
// which compiles the WHERE (a LEFT JOIN role→shared-base, since Document is a
// base field), hydrates the role + its base fields + base children, and returns
// RecordNotFound on a miss. No bespoke SQL.
//
// It also satisfies persistence.SharedBaseInsertLoader[*User] via
// LoadForSharedBaseInsert, so the manual insert handler can hydrate the existing
// Person identity (name + addresses as Constructor items) before a POST — the
// same load the canonical SharedBaseInsertCommandHandler does automatically.
type UserCustomRepository struct {
	eng         core.RelationalEngine
	loader      *read.AggregateLoader[*appdomain.User]
	schema      *core.TableSchema
	contextName string
	constraints map[string]write.ConstraintBinding
}

// NewUserCustomRepository wires the Repository over the shared RelationalEngine
// and builds an AggregateLoader that scans *User + its shared Person base + the
// base's Address children, driven by the explicit UserSchema(). The same
// duplicate-role constraint mapping is copied from UserRepository so a PRIMARY
// KEY violation (shared-PK: users.id == persons.id) reaching this surface emits
// EntityAlreadyAddedNotification (semantic Conflict → 409) instead of leaking
// the raw driver error.
func NewUserCustomRepository(eng core.RelationalEngine) *UserCustomRepository {
	newUser := func() *appdomain.User { return &appdomain.User{} }
	schema := schemas.UserSchema()
	loader := read.NewAggregateLoader[*appdomain.User](eng, newUser).WithSchema(schema)
	return &UserCustomRepository{
		eng:         eng,
		loader:      loader,
		schema:      schema,
		contextName: "User",
		constraints: map[string]write.ConstraintBinding{
			"users_pkey": {Notification: domain.EntityAlreadyAddedNotification{}, Field: "id"},
			"PRIMARY":    {Notification: domain.EntityAlreadyAddedNotification{}, Field: "id"},
		},
	}
}

// ─── Scope: the write binding ───────────────────────────────────────────────
//
// Scope binds the request ctx (cancellation → the driver, actor → audit) and the
// optional in-TX lifecycle hooks, and returns the pure read+write domain port
// appdomain.UserCustomRepository. The returned scopedUserRepo composes this struct
// (for the ctx-free reads) with a userCustomBoundWriter (for the ctx-bound
// writes). Mirrors write.BaseRepository.Scope, written out by hand.

func (r *UserCustomRepository) Scope(ctx *configuration.AppContext, opts ...persistence.WriteOption[*appdomain.User]) appdomain.UserCustomRepository {
	return scopedUserRepo{
		UserCustomRepository: r,
		Writer:               userCustomBoundWriter{r: r, ctx: ctx, opts: opts},
	}
}

// scopedUserRepo is the request-scoped appdomain.UserCustomRepository Scope returns:
// reads promoted from the embedded *UserCustomRepository, writes from the
// embedded (bound) domain.Writer.
type scopedUserRepo struct {
	*UserCustomRepository
	domain.Writer
}

// userCustomBoundWriter is the request-scoped domain.Writer. Each write is the
// same delegation BaseRepository performs internally; writing them out keeps
// the manual contract visible. The explicit UserSchema() (held on the repo) is
// threaded to the persister — same map the canonical repo uses. The captured
// opts thread through core.AdaptWriteOptions so the typed afterBegin /
// beforeCommit closures reach the persister identically to the canonical path.
type userCustomBoundWriter struct {
	r    *UserCustomRepository
	ctx  *configuration.AppContext
	opts []persistence.WriteOption[*appdomain.User]
}

func (w userCustomBoundWriter) Insert(i domain.Insertable) (domain.ID, error) {
	res, err := w.r.eng.Insert(w.ctx, i, w.r.schema, core.AdaptWriteOptions(w.opts))
	if err != nil {
		return domain.ID{}, w.r.mapErr(err)
	}
	return domain.NewID(res.ID.Value()), nil
}

func (w userCustomBoundWriter) Update(u domain.Updatable) error {
	_, err := w.r.eng.Update(w.ctx, u, w.r.schema, core.AdaptWriteOptions(w.opts))
	return w.r.mapErr(err)
}

func (w userCustomBoundWriter) Delete(d domain.Deletable) error {
	return w.r.mapErr(w.r.eng.Delete(w.ctx, d, w.r.schema, core.AdaptWriteOptions(w.opts)))
}

func (w userCustomBoundWriter) Archive(a domain.Archivable) error {
	return w.r.mapErr(w.r.eng.Archive(w.ctx, a, w.r.schema, core.AdaptWriteOptions(w.opts)))
}

func (w userCustomBoundWriter) Unarchive(u domain.Unarchivable) error {
	return w.r.mapErr(w.r.eng.Unarchive(w.ctx, u, w.r.schema, core.AdaptWriteOptions(w.opts)))
}

// ─── Reads (ctx-free, direct on the handle) ─────────────────────────────────

func (r *UserCustomRepository) FindByID(id domain.ID) (*appdomain.User, error) {
	return r.loader.FindOne(context.Background(), criteria.ByID(id))
}

func (r *UserCustomRepository) New() *appdomain.User {
	return &appdomain.User{}
}

// FindArchivedByID satisfies domain.ArchivedFinder[*User].
func (r *UserCustomRepository) FindArchivedByID(id domain.ID) (*appdomain.User, error) {
	return r.loader.FindOne(context.Background(), criteria.ByID(id).OnlyArchived())
}

// FindByDocument loads the active aggregate whose Person document matches, via
// the entity search engine: criteria.Eq("Document", document) compiles to the
// WHERE clause (a LEFT JOIN role→shared-base, since Document is a base field)
// and FindOne hydrates role + base + base children, returning RecordNotFound on
// a miss (same 404 envelope as the canonical by-id miss).
func (r *UserCustomRepository) FindByDocument(document string) (*appdomain.User, error) {
	return r.loader.FindOne(context.Background(), criteria.Where(criteria.Eq("Document", document)))
}

// FindArchivedByDocument is the symmetric inverse used by the Unarchive flow —
// same criterion under the OnlyArchived scope (deleted_at IS NOT NULL), with
// children loaded unfiltered so the cascade sees them.
func (r *UserCustomRepository) FindArchivedByDocument(document string) (*appdomain.User, error) {
	return r.loader.FindOne(context.Background(), criteria.Where(criteria.Eq("Document", document)).OnlyArchived())
}

// LoadForSharedBaseInsert satisfies persistence.SharedBaseInsertLoader[*User]:
// it loads the existing shared Person identity (base fields + the base's
// addresses as Constructor items) by the natural key carried on fresh. The
// manual insert handler calls this BEFORE a POST so the command can dedup the
// request's addresses against the ones the person already has, and so the
// persister's forgot-guard (which rejects a blind insert against a pre-existing
// identity) is satisfied. existed=false → cold insert.
func (r *UserCustomRepository) LoadForSharedBaseInsert(ctx *configuration.AppContext, fresh *appdomain.User) (*appdomain.User, bool, error) {
	return r.loader.LoadSharedBaseIdentity(ctx, fresh)
}

// ─── Constraint-violation translation ───────────────────────────────────────
//
// mapErr replicates what BaseRepository.mapErr does (it is package-private in
// the framework, so we cannot import it). Without this, a unique-constraint
// violation would reach the wire as a 500. With it, the violated constraint
// name — classified backend-neutrally by the engine's Dialect — is looked up in
// r.constraints and the matching Notification is emitted as a typed
// InfrastructureError, same shape the canonical UserRepository produces, on any
// backend.
func (r *UserCustomRepository) mapErr(err error) error {
	if err == nil {
		return nil
	}
	constraint, ok := r.eng.Dialect().IsUniqueViolation(err)
	if !ok {
		return err
	}
	binding, ok := r.constraints[constraint]
	if !ok {
		return err
	}
	return core.FieldErrorWithCause(r.contextName, binding.Field, err, binding.Notification)
}

// Compile-time contract checks: the scoped value is the pure domain read+write
// port; the bound writer is a domain.Writer; the unscoped struct is an
// ArchivedFinder for the unarchive flow.
var (
	_ appdomain.UserCustomRepository                      = scopedUserRepo{}
	_ domain.Writer                                       = userCustomBoundWriter{}
	_ domain.ArchivedFinder[*appdomain.User]              = (*UserCustomRepository)(nil)
	_ persistence.SharedBaseInsertLoader[*appdomain.User] = (*UserCustomRepository)(nil)
)
