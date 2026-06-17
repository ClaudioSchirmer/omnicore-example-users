package infra

import (
	"context"
	"errors"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/criteria"
	"github.com/ClaudioSchirmer/omnicore/domain"
	fwinfra "github.com/ClaudioSchirmer/omnicore/infra"
	"github.com/jackc/pgx/v5/pgconn"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// UserCustomRepository is the manual counterpart to UserRepository, used by
// the /showcase/users-custom/* surface. The canonical UserRepository embeds
// fwinfra.BaseAggregateRepository — New() + FindByID + FindArchivedByID +
// Scope come "for free" via promotion. This struct deliberately does NOT
// embed it: the reads + the scoped-write binding are written out so a reader
// can see what the canonical wrapper hides, and so we can add the email-keyed
// lookups (FindByEmail / FindArchivedByEmail) that no framework primitive
// exposes.
//
// The repository PORT (read+write) is a domain concept — appdomain.UserCustomRepository
// in domain/user_custom_repository.go. This struct is the infra adapter that
// satisfies it: reads are direct (no ctx); writes are bound to the request
// *AppContext via Scope, which returns a value satisfying appdomain.UserCustomRepository
// with its Writer half already scoped. The five writes inside the bound writer
// are 1-line delegations to fwinfra.Postgres — the same primitives
// BaseRepository.Scope calls under the hood.
//
// FindByEmail and FindArchivedByEmail are the actual reason this Repository
// exists. The /:email path identifier on the showcase routes is an alternate
// key the by-id contract does not cover; the custom Repository resolves it
// through the framework's entity search engine — criteria.Eq("Email", email)
// handed to the AggregateLoader's FindOne, which compiles the WHERE, hydrates
// root + children, and returns RecordNotFound on a miss. No bespoke SQL.
type UserCustomRepository struct {
	pg          *fwinfra.Postgres
	loader      *fwinfra.AggregateLoader[*appdomain.User]
	contextName string
	constraints map[string]fwinfra.ConstraintBinding
}

// NewUserCustomRepository wires the Repository over the shared *Postgres and
// builds an AggregateLoader that knows how to scan *User + its Address
// children via reflection. The same email-uniqueness constraint mapping is
// copied from UserRepository so that a PG 23505 violation reaching this
// surface emits EmailAlreadyExistsNotification (semantic Conflict → 409)
// instead of leaking the raw pgErr.
func NewUserCustomRepository(pg *fwinfra.Postgres) *UserCustomRepository {
	newUser := func() *appdomain.User { return &appdomain.User{} }
	loader := fwinfra.NewAggregateLoader[*appdomain.User](pg, newUser)
	fwinfra.WithChild[appdomain.Address](loader)
	return &UserCustomRepository{
		pg:          pg,
		loader:      loader,
		contextName: "User",
		constraints: map[string]fwinfra.ConstraintBinding{
			"users_email_active_idx": {Notification: appdomain.EmailAlreadyExistsNotification{}, Field: "email"},
		},
	}
}

// ─── Scope: the write binding ───────────────────────────────────────────────
//
// Scope binds the request ctx (cancellation → pgx, actor → audit) and the
// optional in-TX lifecycle hooks, and returns the pure read+write domain port
// appdomain.UserCustomRepository. The returned scopedUserRepo composes this struct
// (for the ctx-free reads) with a userCustomBoundWriter (for the ctx-bound
// writes). Mirrors fwinfra.BaseRepository.Scope, written out by hand.

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
// the manual contract visible. RepoConfig is left nil (zero value) — same as
// the canonical repo — so table/column/FK come from convention. The captured
// opts thread through fwinfra.AdaptWriteOptions so the typed afterBegin /
// beforeCommit closures reach the persister identically to the canonical path.
type userCustomBoundWriter struct {
	r    *UserCustomRepository
	ctx  *configuration.AppContext
	opts []persistence.WriteOption[*appdomain.User]
}

func (w userCustomBoundWriter) Insert(i domain.Insertable) (domain.ID, error) {
	res, err := w.r.pg.Insert(w.ctx, i, nil, fwinfra.AdaptWriteOptions(w.opts))
	if err != nil {
		return domain.ID{}, w.r.mapErr(err)
	}
	return domain.NewID(res.ID), nil
}

func (w userCustomBoundWriter) Update(u domain.Updatable) error {
	_, err := w.r.pg.Update(w.ctx, u, nil, fwinfra.AdaptWriteOptions(w.opts))
	return w.r.mapErr(err)
}

func (w userCustomBoundWriter) Delete(d domain.Deletable) error {
	return w.r.mapErr(w.r.pg.Delete(w.ctx, d, nil, fwinfra.AdaptWriteOptions(w.opts)))
}

func (w userCustomBoundWriter) Archive(a domain.Archivable) error {
	return w.r.mapErr(w.r.pg.Archive(w.ctx, a, nil, fwinfra.AdaptWriteOptions(w.opts)))
}

func (w userCustomBoundWriter) Unarchive(u domain.Unarchivable) error {
	return w.r.mapErr(w.r.pg.Unarchive(w.ctx, u, nil, fwinfra.AdaptWriteOptions(w.opts)))
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

// FindByEmail loads the active aggregate whose email matches, via the entity
// search engine: criteria.Eq("Email", email) compiles to the WHERE clause and
// FindOne hydrates root + children, returning RecordNotFound on a miss (same
// 404 envelope as the canonical by-id miss).
func (r *UserCustomRepository) FindByEmail(email string) (*appdomain.User, error) {
	return r.loader.FindOne(context.Background(), criteria.Where(criteria.Eq("Email", email)))
}

// FindArchivedByEmail is the symmetric inverse used by the Unarchive flow —
// same criterion under the OnlyArchived scope (deleted_at IS NOT NULL), with
// children loaded unfiltered so the cascade sees them.
func (r *UserCustomRepository) FindArchivedByEmail(email string) (*appdomain.User, error) {
	return r.loader.FindOne(context.Background(), criteria.Where(criteria.Eq("Email", email)).OnlyArchived())
}

// ─── Constraint-violation translation ───────────────────────────────────────
//
// mapErr replicates what BaseRepository.mapErr does (it is package-private in
// the framework, so we cannot import it). Without this, a PG 23505 unique
// violation would reach the wire as a 500. With it, the constraint name is
// looked up in r.constraints and the matching Notification is emitted as a
// typed InfrastructureError — same shape the canonical UserRepository produces.
func (r *UserCustomRepository) mapErr(err error) error {
	if err == nil {
		return nil
	}
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "23505" {
		return err
	}
	binding, ok := r.constraints[pgErr.ConstraintName]
	if !ok {
		return err
	}
	return fwinfra.FieldErrorWithCause(r.contextName, binding.Field, pgErr, binding.Notification)
}

// Compile-time contract checks: the scoped value is the pure domain read+write
// port; the bound writer is a domain.Writer; the unscoped struct is an
// ArchivedFinder for the unarchive flow.
var (
	_ appdomain.UserCustomRepository               = scopedUserRepo{}
	_ domain.Writer                          = userCustomBoundWriter{}
	_ domain.ArchivedFinder[*appdomain.User] = (*UserCustomRepository)(nil)
)
