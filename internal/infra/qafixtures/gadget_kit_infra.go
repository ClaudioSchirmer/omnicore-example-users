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

// GadgetKitSchema is the flat root map for qa_gadget_kits, declaring the native
// child qa_gadget_kit_lines.
func GadgetKitSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[*qadomain.GadgetKit]("qa_gadget_kits").
		PK("id").
		Revision("revision").
		Field("Name", "name").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at").
		Child(GadgetKitLineSchema())
}

// GadgetKitLineSchema is the native child of GadgetKit: FK gadget_kit_id back to
// the root, gadget_id the FK enriched via EmbedInChild (→ upstream_gadgets._id).
func GadgetKitLineSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[qadomain.GadgetKitLine]("qa_gadget_kit_lines").
		PK("id").
		FK("gadget_kit_id").
		Field("GadgetID", "gadget_id").
		Field("Note", "note").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}

// GadgetKitView is the EmbedInChild proof over the upstream_gadgets projection:
// each native kit line is enriched 1:1 with its upstream gadget mirror
// (code/name), keyed by the line's own gadget_id → upstream_gadgets._id. It
// reuses the SAME GadgetUpstreamMirrorSchema()/upstream_gadgets projection the
// gadgets_embedded view uses — proving EmbedInChild rides the cross-service
// upstream/ripple path end to end, without touching GadgetSchema.
func GadgetKitView() *query.ViewDefinition {
	lineGadget := query.FromSchema(GadgetUpstreamMirrorSchema()).
		FK("gadget_id").
		As("Gadget")
	return query.View("qa_gadget_kits_view").
		Version(1).
		Schema(GadgetKitSchema()).
		EmbedInChild(GadgetKitLineSchema(), "gadget", lineGadget).
		Indexes(
			// Covering multikey index for the EmbedInChild ripple's reverse scan
			// ("<childSegment>.<fk>" = GadgetKitLines.gadget_id) — mandatory at boot.
			query.Index("GadgetKitLines.gadget_id"),
		)
}

// GadgetKitRepository is the flat aggregate-aware repository for GadgetKit.
type GadgetKitRepository struct {
	read.BaseAggregateRepository[*qadomain.GadgetKit]
}

func NewGadgetKitRepository(eng fwdb.RelationalEngine) *GadgetKitRepository {
	r := &GadgetKitRepository{
		BaseAggregateRepository: read.NewBaseAggregateRepository[*qadomain.GadgetKit](
			eng,
			func() *qadomain.GadgetKit { return &qadomain.GadgetKit{} },
		),
	}
	r.WithSchema(GadgetKitSchema())
	return r
}

var _ persistence.ScopedRepository[*qadomain.GadgetKit] = (*GadgetKitRepository)(nil)

// ProvisionGadgetKitTables creates qa_gadget_kits + qa_gadget_kit_lines if
// absent, dialect-aware (idempotent, engine side-channel, no migration files).
func ProvisionGadgetKitTables(ctx context.Context, eng fwdb.RelationalEngine) error {
	postgres := eng.Dialect().Placeholder(1) == "$1"

	var kits, lines string
	if postgres {
		kits = `CREATE TABLE IF NOT EXISTS qa_gadget_kits (
			id          UUID         PRIMARY KEY,
			revision    BIGINT       NOT NULL DEFAULT 0,
			name        VARCHAR(255) NOT NULL,
			deleted_at  TIMESTAMP,
			created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
		lines = `CREATE TABLE IF NOT EXISTS qa_gadget_kit_lines (
			id             UUID         PRIMARY KEY,
			gadget_kit_id  UUID         NOT NULL REFERENCES qa_gadget_kits(id) ON DELETE CASCADE,
			gadget_id      VARCHAR(36),
			note           VARCHAR(255) NOT NULL,
			deleted_at     TIMESTAMP,
			created_at     TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at     TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
	} else {
		kits = `CREATE TABLE IF NOT EXISTS qa_gadget_kits (
			id          BINARY(16)   NOT NULL,
			revision    BIGINT       NOT NULL DEFAULT 0,
			name        VARCHAR(255) NOT NULL,
			deleted_at  DATETIME     NULL,
			created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id)
		)`
		lines = `CREATE TABLE IF NOT EXISTS qa_gadget_kit_lines (
			id             BINARY(16)   NOT NULL,
			gadget_kit_id  BINARY(16)   NOT NULL,
			gadget_id      VARCHAR(36)  NULL,
			note           VARCHAR(255) NOT NULL,
			deleted_at     DATETIME     NULL,
			created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id),
			CONSTRAINT fk_qa_gadget_kit_lines FOREIGN KEY (gadget_kit_id) REFERENCES qa_gadget_kits (id) ON DELETE CASCADE
		)`
	}
	return qaExecDDL(ctx, eng, kits, lines)
}
