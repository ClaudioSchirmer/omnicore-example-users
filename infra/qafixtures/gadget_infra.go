//go:build qa

// Package qafixtures (infra layer) owns the relational + read-side wiring for
// the QA-only Gadget aggregate: its flat TableSchema, its Mongo view, its
// repository over the neutral relational engine, the journal adapter (the
// in-TX side-effect port implementation), and idempotent self-provisioning of
// the `gadgets` + `gadget_journal` tables so no migration file leaks into the
// canonical migration set. All gated behind the `qa` build tag.
package qafixtures

import (
	"context"
	"fmt"

	"github.com/google/uuid"

	"github.com/ClaudioSchirmer/omnicore/application/configuration"
	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/domain"
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/read"
	fwdb "github.com/ClaudioSchirmer/omnicore/infra/db/core"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
	fwintegration "github.com/ClaudioSchirmer/omnicore/infra/integration"

	appqa "github.com/ClaudioSchirmer/omnicore-example-users/application/qafixtures"
	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/domain/qafixtures"
)

// GadgetSchema is the FLAT Go↔column map for the gadgets table: PK + four
// business columns + the managed columns (soft-delete, created/updated). No
// SharedBase, no children — the single-table write path.
func GadgetSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[*qadomain.Gadget]("gadgets").
		PK("id").
		Field("Code", "code").
		Field("Name", "name").
		Field("Category", "category").
		Field("Status", "status").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}

// GadgetView is the read-side projection of the Gadget aggregate for MongoDB.
// It reuses the SAME schema the repository declares so the composer and the
// reader agree on every name across write and read.
func GadgetView() *query.ViewDefinition {
	return query.View("gadgets").
		Version(1).
		Root("gadgets").
		Schema(GadgetSchema()).
		Indexes(
			query.Index("code"),
			query.Index("created_at").Desc(),
			query.TextIndex("name", "category").DefaultLanguage("english"),
		)
}

// GadgetHotView is a SECOND read-side projection over the SAME `gadgets` root,
// opting into .DeleteOnArchive() and landing in its own `gadgets_hot` Mongo
// collection. It is the hot-tier counterpart to GadgetView: an ARCHIVED gadget
// is DROPPED from `gadgets_hot` (the composer applies WHERE deleted_at IS NULL),
// whereas the default `gadgets` view keeps the archived document (hidden unless
// ?includeArchived=true). Same root table, distinct collection — CDC recomposes
// both on every gadgets change.
func GadgetHotView() *query.ViewDefinition {
	return query.View("gadgets_hot").
		Version(1).
		Root("gadgets").
		Schema(GadgetSchema()).
		DeleteOnArchive().
		Indexes(
			query.Index("code"),
			query.Index("created_at").Desc(),
		)
}

// GadgetCappedView is a THIRD projection over the SAME `gadgets` root, landing
// in the `gadgets_capped` collection with a small per-view .MaxLimit(5). A read
// against it with ?limit greater than 5 is rejected with 400
// LimitExceededNotification at read time (the reader's per-view ceiling), while
// the default `gadgets` view keeps the framework default of 100.
func GadgetCappedView() *query.ViewDefinition {
	return query.View("gadgets_capped").
		Version(1).
		Root("gadgets").
		Schema(GadgetSchema()).
		MaxLimit(5).
		Indexes(
			query.Index("code"),
			query.Index("created_at").Desc(),
		)
}

// GadgetUpstreamMirrorSchema is the type-less EXTERNAL schema describing the
// `upstream_gadgets` Mongo collection — the local, filtered projection the
// UpstreamSubscriber materializes from the service's OWN gadgets CDC topic
// (declared under upstreamSubscriptions in microservice.qa.yaml, filter
// [id, code, name]). It carries only the allow-listed columns; there is no Go
// struct to anchor it (the columns belong to the upstream event), so the leaf
// names are declared inline. PK("id") is the collection's document key — the
// UpstreamSubscriber upserts each doc under _id = the gadget's aggregate id, so
// the composer's one-to-one join (parent gadget.id → source _id) resolves the
// mirror.
func GadgetUpstreamMirrorSchema() *fwdb.TableSchema {
	return fwdb.NewExternalSchema("upstream_gadgets").
		PK("id").
		Field("Code", "code").
		Field("Name", "name")
}

// GadgetComposedView is a FOURTH projection over the SAME `gadgets` root,
// landing in the `gadgets_composed` collection. Unlike the other three, it
// COMPOSES: besides the flat gadget it one-to-one-embeds the `upstream_gadgets`
// projection under the "UpstreamMirror" segment via an external FromSchema. This
// is the read surface that closes the upstream-composition loop end to end —
// without it the materialized `upstream_gadgets` collection is only observable
// by poking Mongo directly; here it is served through a normal ViewReader
// endpoint (GET /qa/gadgets-composed/:id).
//
// The embed proves the whole ripple pipeline: an `upstream_gadgets` event
// triggers recompose-ripple on this view (auto-registered via
// query.DependentMongoViews), so reading the composed doc reflects the current
// mirror. Because the upstream filter keeps only [id, code, name], the nested
// mirror deliberately omits category/status — reading it shows exactly what
// survived the projection filter, next to the full root gadget.
//
//   - .On("id") joins the parent gadget's id column to the mirror doc's _id.
//   - .As("UpstreamMirror") names the Go segment (external sources have no Go
//     type to derive it from — mandatory).
//   - query.Index("id") is the §8.1 covering index on the one-to-one join field
//     (the ripple's FindIDsByField consults it on every upstream event).
func GadgetComposedView() *query.ViewDefinition {
	mirror := query.FromSchema(GadgetUpstreamMirrorSchema()).
		On("id").
		As("UpstreamMirror")
	return query.View("gadgets_composed").
		Version(1).
		Root("gadgets").
		Schema(GadgetSchema()).
		Embed("upstreamMirror", mirror).
		Indexes(
			query.Index("id"),
			query.Index("code"),
			query.Index("created_at").Desc(),
		)
}

// GadgetRepository is the flat aggregate-aware repository for Gadget. It embeds
// BaseAggregateRepository (the canonical common case): 5 writes + New() +
// schema-driven FindByID/Scope, satisfying persistence.ScopedRepository.
type GadgetRepository struct {
	read.BaseAggregateRepository[*qadomain.Gadget]
}

func NewGadgetRepository(eng fwdb.RelationalEngine) *GadgetRepository {
	r := &GadgetRepository{
		BaseAggregateRepository: read.NewBaseAggregateRepository[*qadomain.Gadget](
			eng,
			func() *qadomain.Gadget { return &qadomain.Gadget{} },
		),
	}
	r.WithSchema(GadgetSchema())
	return r
}

var _ persistence.ScopedRepository[*qadomain.Gadget] = (*GadgetRepository)(nil)

// ─── Journal adapter — the in-TX side-effect port implementation ────────────

// GadgetJournalAdapter implements application/qafixtures.GadgetJournal. It
// recovers the neutral Tx via fwdb.UnwrapTx and writes one gadget_journal row
// per hook call, rendering placeholders through the dialect so the SAME SQL
// runs on postgres ($n) and mysql (?). The row id is a fresh UUIDv7; created_at
// is filled by the column default.
type GadgetJournalAdapter struct{}

func (GadgetJournalAdapter) Write(
	ctx *configuration.AppContext, tx persistence.TxHandle, gadgetID, phase string,
) error {
	x := fwdb.UnwrapTx(tx)
	d := x.Dialect()

	sql := fmt.Sprintf(
		"INSERT INTO gadget_journal (id, gadget_id, phase) VALUES (%s, %s, %s)",
		d.Placeholder(1), d.Placeholder(2), d.Placeholder(3),
	)

	rowID := domain.NewIDFromUUID(uuid.Must(uuid.NewV7()))

	// gadget_id is nullable: empty on the pre-write phase (no id yet), the
	// encoded gadget id on the post-write phase.
	var gid any
	if gadgetID != "" {
		gid = d.EncodeArg(domain.NewID(gadgetID))
	}

	return x.Exec(ctx, sql, d.EncodeArg(rowID), gid, phase)
}

// ─── Integration producer adapter — the publish port implementation ─────────

// GadgetEventPublisherAdapter implements application/qafixtures.GadgetEventPublisher.
// It threads the caller's in-flight TX into fwintegration.Dispatch (WithTx) so
// the integration_events row lands atomically with the gadget + journal + outbox
// + audit writes, and stamps the aggregate identity (WithAggregateID). The
// declarative bits — event_type "GadgetCreated", aggregate "Gadget", version —
// resolve from the YAML publishes block under eventKey "gadgetCreated".
type GadgetEventPublisherAdapter struct{}

func (GadgetEventPublisherAdapter) Publish(
	ctx *configuration.AppContext, tx persistence.TxHandle, id domain.ID, evt appqa.GadgetCreatedEvent,
) error {
	return fwintegration.Dispatch(ctx, "gadgetCreated", evt,
		fwintegration.WithTx(tx),
		fwintegration.WithAggregateID(id),
	)
}

var _ appqa.GadgetEventPublisher = GadgetEventPublisherAdapter{}

// ─── Integration consumer adapter — the idempotent sink-write port ──────────

// GadgetEventSinkAdapter implements application/qafixtures.GadgetEventSink. The
// receiver path carries no outer TX (framework invariant #10), so the write is a
// single-statement autocommit through the engine's neutral Querier, rendered
// dialect-appropriately. Idempotency (at-least-once delivery) rides the
// gadget_id primary key: ON CONFLICT DO NOTHING on postgres, INSERT IGNORE on
// mysql — a redelivered event is a silent no-op.
type GadgetEventSinkAdapter struct {
	eng fwdb.RelationalEngine
}

func NewGadgetEventSinkAdapter(eng fwdb.RelationalEngine) *GadgetEventSinkAdapter {
	return &GadgetEventSinkAdapter{eng: eng}
}

func (a *GadgetEventSinkAdapter) Record(
	ctx *configuration.AppContext, cmd *appqa.RecordGadgetEventCommand,
) error {
	q := a.eng.Querier()
	d := a.eng.Dialect()
	postgres := d.Placeholder(1) == "$1"

	var sql string
	if postgres {
		sql = fmt.Sprintf(
			"INSERT INTO gadget_events_sink (gadget_id, code, name, category, status) "+
				"VALUES (%s, %s, %s, %s, %s) ON CONFLICT (gadget_id) DO NOTHING",
			d.Placeholder(1), d.Placeholder(2), d.Placeholder(3), d.Placeholder(4), d.Placeholder(5),
		)
	} else {
		sql = fmt.Sprintf(
			"INSERT IGNORE INTO gadget_events_sink (gadget_id, code, name, category, status) "+
				"VALUES (%s, %s, %s, %s, %s)",
			d.Placeholder(1), d.Placeholder(2), d.Placeholder(3), d.Placeholder(4), d.Placeholder(5),
		)
	}

	return q.Exec(ctx, sql,
		d.EncodeArg(domain.NewID(cmd.GadgetID)),
		cmd.Code, cmd.Name, cmd.Category, cmd.Status,
	)
}

var _ appqa.GadgetEventSink = (*GadgetEventSinkAdapter)(nil)

// ─── Self-provisioning (no migration files) ─────────────────────────────────

// ProvisionGadgetTables creates the `gadgets`, `gadget_journal`, and
// `gadget_events_sink` tables if they do not exist, dialect-aware (postgres
// UUID/TIMESTAMP, mysql BINARY(16)/DATETIME — mirroring the
// migrations/{postgres,mysql}/0002 types).
// Idempotent; runs off the engine's neutral side-channel exec at feature Mount
// so the QA schema stays entirely out of the canonical migration set. The
// dialect is detected from the placeholder form ($1 ⇒ postgres, else mysql).
func ProvisionGadgetTables(ctx context.Context, eng fwdb.RelationalEngine) error {
	q := eng.Querier()
	postgres := eng.Dialect().Placeholder(1) == "$1"

	var gadgets, journal, sink string
	if postgres {
		gadgets = `CREATE TABLE IF NOT EXISTS gadgets (
			id          UUID         PRIMARY KEY,
			code        VARCHAR(64)  NOT NULL,
			name        VARCHAR(255) NOT NULL,
			category    VARCHAR(128) NOT NULL,
			status      VARCHAR(32)  NOT NULL,
			deleted_at  TIMESTAMP,
			created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
			CONSTRAINT gadgets_code_key UNIQUE (code)
		)`
		journal = `CREATE TABLE IF NOT EXISTS gadget_journal (
			id          UUID         PRIMARY KEY,
			gadget_id   UUID,
			phase       VARCHAR(32)  NOT NULL,
			created_at  TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
		sink = `CREATE TABLE IF NOT EXISTS gadget_events_sink (
			gadget_id   UUID         PRIMARY KEY,
			code        VARCHAR(64)  NOT NULL,
			name        VARCHAR(255) NOT NULL,
			category    VARCHAR(128) NOT NULL,
			status      VARCHAR(32)  NOT NULL,
			received_at TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
	} else {
		gadgets = `CREATE TABLE IF NOT EXISTS gadgets (
			id          BINARY(16)   NOT NULL,
			code        VARCHAR(64)  NOT NULL,
			name        VARCHAR(255) NOT NULL,
			category    VARCHAR(128) NOT NULL,
			status      VARCHAR(32)  NOT NULL,
			deleted_at  DATETIME     NULL,
			created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id),
			UNIQUE KEY gadgets_code_key (code)
		)`
		journal = `CREATE TABLE IF NOT EXISTS gadget_journal (
			id          BINARY(16)   NOT NULL,
			gadget_id   BINARY(16)   NULL,
			phase       VARCHAR(32)  NOT NULL,
			created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id)
		)`
		sink = `CREATE TABLE IF NOT EXISTS gadget_events_sink (
			gadget_id   BINARY(16)   NOT NULL,
			code        VARCHAR(64)  NOT NULL,
			name        VARCHAR(255) NOT NULL,
			category    VARCHAR(128) NOT NULL,
			status      VARCHAR(32)  NOT NULL,
			received_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (gadget_id)
		)`
	}

	if err := q.Exec(ctx, gadgets); err != nil {
		return err
	}
	if err := q.Exec(ctx, journal); err != nil {
		return err
	}
	return q.Exec(ctx, sink)
}
