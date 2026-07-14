//go:build qa

package qafixtures

import (
	"context"

	"github.com/ClaudioSchirmer/omnicore/application/persistence"
	"github.com/ClaudioSchirmer/omnicore/infra/db/command/read"
	fwdb "github.com/ClaudioSchirmer/omnicore/infra/db/core"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// GadgetNoteSchema is the FLAT Go↔column map for the gadget_notes table. The
// gadget_id column is a plain foreign key to gadgets.id — no aggregate child,
// no shared base, no embed: the two aggregates are write-side strangers, which
// is exactly what makes them the composed-read showcase pair.
func GadgetNoteSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[*qadomain.GadgetNote]("gadget_notes").
		PK("id").
		Field("GadgetID", "gadget_id").
		Field("Text", "text").
		Field("Kind", "kind").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}

// GadgetNotesView is the note's OWN read-side projection — a perfectly normal
// view (collection `gadget_notes`, CDC-materialized). The composed view links
// it as a leg, but nothing about it is composed-specific: it is filterable,
// sortable and pageable directly (GET /qa/gadget-notes), which is also how a
// consumer reaches the full set when a composed segment truncates.
// query.Index("gadget_id") covers the LinkMany leg fetches (leg FK equality).
func GadgetNotesView() *query.ViewDefinition {
	return query.View("gadget_notes").
		Version(1).
		Root("gadget_notes").
		Schema(GadgetNoteSchema()).
		Indexes(
			query.Index("gadget_id"),
			query.Index("created_at").Desc(),
		)
}

// GadgetFullView is the READ-TIME composition showcase — the direct-query
// counterpart of GadgetEmbeddedView's materialization path, over the same
// upstream-mirror data:
//
//   - GadgetEmbeddedView (write-time): Embed materializes `gadgets_embedded`,
//     one more collection, one more Version, recompose-ripple on every event.
//   - GadgetFullView (read-time): NO collection, NO Version, NO sync — a read
//     against "gadgets_full" reads the `gadgets` view as primary and enriches
//     each item in batch from views that already exist.
//
// Legs:
//   - 1:1 external — the primary holds the FK ("id" = the gadget's PK →
//     upstream doc _id), same join the Embed declares, resolved at read time.
//   - 1:N internal — the leg holds the FK (gadget_notes.gadget_id →
//     gadget _id). OrderBy("text") keeps the QA assertions deterministic
//     regardless of insert timing; MaxLinkManyLimit(3) makes the per-parent
//     truncation observable ("the first 3 in the declared order").
func GadgetFullView() *query.ComposedViewDefinition {
	return query.ComposedView("gadgets_full").
		Primary(GadgetView()).
		Link("upstreamMirror", query.JoinUpstream(GadgetUpstreamMirrorSchema()).
			FK("id").
			As("UpstreamMirror")).
		LinkMany("notes", query.JoinView(GadgetNotesView()).
			FK("gadget_id").
			As("Notes").
			OrderBy("text").
			MaxLinkManyLimit(3))
}

// GadgetNoteRepository is the flat aggregate-aware repository for GadgetNote,
// the same canonical BaseAggregateRepository shape GadgetRepository uses.
type GadgetNoteRepository struct {
	read.BaseAggregateRepository[*qadomain.GadgetNote]
}

func NewGadgetNoteRepository(eng fwdb.RelationalEngine) *GadgetNoteRepository {
	r := &GadgetNoteRepository{
		BaseAggregateRepository: read.NewBaseAggregateRepository[*qadomain.GadgetNote](
			eng,
			func() *qadomain.GadgetNote { return &qadomain.GadgetNote{} },
		),
	}
	r.WithSchema(GadgetNoteSchema())
	return r
}

var _ persistence.ScopedRepository[*qadomain.GadgetNote] = (*GadgetNoteRepository)(nil)

// ProvisionGadgetNoteTable creates the `gadget_notes` table if it does not
// exist, dialect-aware, mirroring ProvisionGadgetTables (idempotent, engine
// side-channel, no migration files).
func ProvisionGadgetNoteTable(ctx context.Context, eng fwdb.RelationalEngine) error {
	postgres := eng.Dialect().Placeholder(1) == "$1"

	var notes string
	if postgres {
		notes = `CREATE TABLE IF NOT EXISTS gadget_notes (
			id          UUID         PRIMARY KEY,
			gadget_id   UUID         NOT NULL,
			text        VARCHAR(255) NOT NULL,
			kind        VARCHAR(16)  NOT NULL,
			deleted_at  TIMESTAMP,
			created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
	} else {
		notes = `CREATE TABLE IF NOT EXISTS gadget_notes (
			id          BINARY(16)   NOT NULL,
			gadget_id   BINARY(16)   NOT NULL,
			text        VARCHAR(255) NOT NULL,
			kind        VARCHAR(16)  NOT NULL,
			deleted_at  DATETIME     NULL,
			created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id)
		)`
	}
	return qaExecDDL(ctx, eng, notes)
}
