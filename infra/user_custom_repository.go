package infra

import (
	"context"
	"errors"

	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/domain"
	fwinfra "github.com/ClaudioSchirmer/omnicore/infra"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// UserCustomRepository is the manual counterpart to UserRepository, used by
// the /showcase/users-custom/* surface. The canonical UserRepository embeds
// fwinfra.BaseAggregateRepository — five writes + New() + FindByID +
// FindArchivedByID come "for free" via promotion. This struct deliberately
// does NOT embed it: every method is written out so a reader can see what
// the canonical wrapper hides, and so we can add the email-keyed lookups
// (FindByEmail / FindArchivedByEmail) that no framework primitive exposes.
//
// The five writes are 1-line delegations to fwinfra.Postgres — the framework
// primitives that BaseRepository itself calls under the hood. Going further
// (managing pgx.Tx + outbox INSERT + aggregate cascade by hand) would risk
// breaking the framework's "outbox is atomic with the write" invariant for
// no didactic gain — the engineering of that transaction is already inside
// fwinfra.Postgres and is not part of what "manual" means in this showcase.
// What is manual here lives one layer above: the Repository shape, the email
// lookups, and the constraint-violation translation.
//
// FindByEmail and FindArchivedByEmail are the actual reason this Repository
// exists. The /:email path identifier on the showcase routes cannot reuse
// FindByID — pgx + the AggregateLoader only know how to find by primary key.
// The custom Repository resolves the email → UUID with a small bespoke SELECT
// and then delegates the aggregate hydration to the framework's loader, which
// already knows how to assemble root + children via reflection.
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

// ─── persistence.Writer[*User] + domain.Repository[*User] ──────────────────
//
// Each delegation is the same one BaseRepository performs internally; writing
// them out keeps the manual contract visible. RepoConfig is left as zero
// value — same as the canonical repo — so table/column/FK come from
// convention (users, name/email/phone, addresses.user_id). The variadic
// opts thread through to fwinfra.AdaptWriteOptions so the typed
// persistence.WriteOption[*User] closures (afterBegin / beforeCommit) fired
// by Auto and manual callers reach the persister identically to the
// canonical path.

func (r *UserCustomRepository) Insert(ctx domain.Context, i domain.Insertable, opts ...persistence.WriteOption[*appdomain.User]) (domain.ID, error) {
	res, err := r.pg.Insert(ctx, i, nil, fwinfra.AdaptWriteOptions(opts))
	if err != nil {
		return domain.ID{}, r.mapErr(err)
	}
	return domain.NewID(res.ID), nil
}

func (r *UserCustomRepository) Update(ctx domain.Context, u domain.Updatable, opts ...persistence.WriteOption[*appdomain.User]) error {
	_, err := r.pg.Update(ctx, u, nil, fwinfra.AdaptWriteOptions(opts))
	return r.mapErr(err)
}

func (r *UserCustomRepository) Delete(ctx domain.Context, d domain.Deletable, opts ...persistence.WriteOption[*appdomain.User]) error {
	return r.mapErr(r.pg.Delete(ctx, d, nil, fwinfra.AdaptWriteOptions(opts)))
}

func (r *UserCustomRepository) Archive(ctx domain.Context, a domain.Archivable, opts ...persistence.WriteOption[*appdomain.User]) error {
	return r.mapErr(r.pg.Archive(ctx, a, nil, fwinfra.AdaptWriteOptions(opts)))
}

func (r *UserCustomRepository) Unarchive(ctx domain.Context, u domain.Unarchivable, opts ...persistence.WriteOption[*appdomain.User]) error {
	return r.mapErr(r.pg.Unarchive(ctx, u, nil, fwinfra.AdaptWriteOptions(opts)))
}

func (r *UserCustomRepository) FindByID(id domain.ID) (*appdomain.User, error) {
	return r.loader.Load(context.Background(), id)
}

func (r *UserCustomRepository) New() *appdomain.User {
	return &appdomain.User{}
}

// ─── domain.ArchivedFinder[*User] ──────────────────────────────────────────

func (r *UserCustomRepository) FindArchivedByID(id domain.ID) (*appdomain.User, error) {
	return r.loader.LoadIncludingArchived(context.Background(), id)
}

// ─── Email-keyed lookups (this Repository's reason to exist) ────────────────

// FindByEmail resolves the email to its UUID and then delegates the
// aggregate hydration to the framework loader. Two queries instead of one,
// but the second one reuses every benefit of AggregateLoader (auto-scan of
// root + children, deleted_at filter, RecordNotFound on miss) — collapsing
// both into a single hand-rolled SELECT would mean re-implementing all that
// here. The miss case short-circuits with NotFoundError so the wire layer
// sees the same 404 envelope as the canonical FindByID miss.
func (r *UserCustomRepository) FindByEmail(email string) (*appdomain.User, error) {
	id, err := r.lookupID(context.Background(), email, false)
	if err != nil {
		return nil, err
	}
	return r.loader.Load(context.Background(), id)
}

// FindArchivedByEmail is the symmetric inverse used by the Unarchive flow.
// Same two-step shape, only the deleted_at filter flips.
func (r *UserCustomRepository) FindArchivedByEmail(email string) (*appdomain.User, error) {
	id, err := r.lookupID(context.Background(), email, true)
	if err != nil {
		return nil, err
	}
	return r.loader.LoadIncludingArchived(context.Background(), id)
}

// lookupID is the small bespoke SELECT. The deleted_at filter flips with
// includeArchived: false → "find the active row with this email"; true →
// "find the archived row" (semantic of Unarchive). pgx.ErrNoRows becomes a
// domain RecordNotFoundNotification so the wire emits 404.
func (r *UserCustomRepository) lookupID(ctx context.Context, email string, includeArchived bool) (domain.ID, error) {
	sql := `SELECT id FROM users WHERE email = $1 AND deleted_at IS NULL`
	if includeArchived {
		sql = `SELECT id FROM users WHERE email = $1 AND deleted_at IS NOT NULL`
	}
	var id string
	err := r.pg.Pool().QueryRow(ctx, sql, email).Scan(&id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ID{}, domain.NotFoundError(r.contextName, "email", email)
		}
		return domain.ID{}, err
	}
	return domain.NewID(id), nil
}

// ─── Constraint-violation translation ───────────────────────────────────────
//
// mapErr replicates what BaseRepository.mapErr does (it is package-private in
// the framework, so we cannot import it). Without this, a PG 23505 unique
// violation would reach the wire as a 500. With it, the constraint name is
// looked up in r.constraints and the matching Notification is emitted as a
// typed InfrastructureError — same shape the canonical UserRepository
// produces.
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

// Compile-time contract checks — the custom Repository satisfies both the
// application-layer write port and the domain read port, plus
// ArchivedFinder for the unarchive flow.
var (
	_ persistence.Writer[*appdomain.User]    = (*UserCustomRepository)(nil)
	_ domain.Repository[*appdomain.User]     = (*UserCustomRepository)(nil)
	_ domain.ArchivedFinder[*appdomain.User] = (*UserCustomRepository)(nil)
)
