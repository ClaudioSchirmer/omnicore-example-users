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

// The MATERIALIZED view-on-view family. Two hops of query.JoinView embeds over
// the EXISTING `gadgets` view — nothing about the upstream-mirror showcase is
// touched, so both composition roads run side by side in one service:
//
//	gadgets ──1:1 Embed──▶ qa_lens_parts_view ──1:N EmbedMany──▶ qa_lens_kits_view
//
// A write to a gadget refreshes the parts that reference it (hop 1), and each of
// those writes refreshes the kits holding them (hop 2) — the chain propagates
// with nothing declared about it.

// LensBrandSchema is the flat root map for qa_lens_brands — the deepest root of
// the chain.
func LensBrandSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[*qadomain.LensBrand]("qa_lens_brands").
		PK("id").
		Revision("revision").
		Field("Name", "name").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}

// LensBrandsView is HOP 0: a plain view with no embeds — the leaf of the chain,
// and the source whose renames the suite follows two hops out.
func LensBrandsView() *query.ViewDefinition {
	return query.View("qa_lens_brands_view").
		Version(1).
		Schema(LensBrandSchema()).
		Indexes(query.Index("name"))
}

// LensKitSchema is the flat root map for qa_lens_kits.
func LensKitSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[*qadomain.LensKit]("qa_lens_kits").
		PK("id").
		Revision("revision").
		Field("Name", "name").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}

// LensPartSchema is the flat root map for qa_lens_parts. kit_id and gadget_id
// are PLAIN foreign keys — the join columns the two embeds resolve on, never
// aggregate containment.
func LensPartSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[*qadomain.LensPart]("qa_lens_parts").
		PK("id").
		Revision("revision").
		Field("KitID", "kit_id").
		Field("GadgetID", "gadget_id").
		Field("BrandID", "brand_id").
		Field("Label", "label").
		Field("Slot", "slot").
		SoftDelete("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at")
}

// LensPartsView is HOP 1: the part's own projection, embedding TWO local views
// 1:1 — the `gadgets` view this family does not own (proving any registered view
// is embeddable) and `qa_lens_brands_view` (whose renames the suite follows two
// hops out, since the gadget fixture exposes no update verb).
//
// The index declarations are both load-bearing at boot:
//   - Index("gadget_id") covers the 1:1 ripple's reverse scan (which parts
//     reference the changed gadget?) — the framework rejects the view without it;
//   - Index("kit_id") covers the lookup the KITS view runs per parent document
//     when it embeds this view 1:N — the guard the framework applies to an
//     EmbedMany over a view leg, checked on THIS (the source) view.
func LensPartsView() *query.ViewDefinition {
	return query.View("qa_lens_parts_view").
		Version(1).
		Schema(LensPartSchema()).
		Embed(query.JoinView(GadgetView(), "Gadget", "gadget")).On("gadget_id").
		Embed(query.JoinView(LensBrandsView(), "Brand", "brand")).On("brand_id").
		Indexes(
			query.Index("gadget_id"),
			query.Index("brand_id"),
			query.Index("kit_id"),
			query.Index("slot"),
			query.Index("created_at").Desc(),
		)
}

// LensKitsView is HOP 2: the kit's projection, embedding the PARTS VIEW 1:N
// under "parts" by each part's kit_id, ORDERED by the part's slot. Every element therefore carries the
// part's own fields AND the gadget sub-document hop 1 materialized into it —
// the embed-of-embed shape, kept fresh by the chained ripple.
func LensKitsView() *query.ViewDefinition {
	return query.View("qa_lens_kits_view").
		Version(1).
		Schema(LensKitSchema()).
		// OrderBy makes the materialized array DETERMINISTIC: every writer (first
		// compose, rebuild backfill, surgical ripple) sorts through the same
		// pipeline operator, so the stored order is the declared one — not an
		// accident of write arrival. Requires MongoDB 5.2+.
		EmbedMany(query.JoinView(LensPartsView(), "Parts", "parts")).OrderBy("slot").On("kit_id").
		Indexes(
			query.Index("name"),
			query.Index("created_at").Desc(),
		)
}

// LensKitsDescView is a SECOND projection over the SAME qa_lens_kits root (the
// pattern gadgets/gadgets_hot already use), declaring the opposite element
// order. It exists so the suite can observe .Desc() end to end: one root event
// materializes both collections, so the two orders are produced by the same
// writers from the same source — any divergence is the ordering itself, not the
// data.
func LensKitsDescView() *query.ViewDefinition {
	return query.View("qa_lens_kits_desc_view").
		Version(1).
		Schema(LensKitSchema()).
		EmbedMany(query.JoinView(LensPartsView(), "Parts", "parts")).OrderBy("slot").Desc().On("kit_id").
		Indexes(query.Index("name"))
}

// LensBrandRepository / LensKitRepository / LensPartRepository are the flat repositories for the two
// roots (no children, no siblings — the composition lives entirely on the read
// side).
type LensBrandRepository struct {
	read.BaseAggregateRepository[*qadomain.LensBrand]
}

func NewLensBrandRepository(eng fwdb.RelationalEngine) *LensBrandRepository {
	r := &LensBrandRepository{
		BaseAggregateRepository: read.NewBaseAggregateRepository[*qadomain.LensBrand](
			eng, func() *qadomain.LensBrand { return &qadomain.LensBrand{} },
		),
	}
	r.WithSchema(LensBrandSchema())
	return r
}

var _ persistence.ScopedRepository[*qadomain.LensBrand] = (*LensBrandRepository)(nil)

type LensKitRepository struct {
	read.BaseAggregateRepository[*qadomain.LensKit]
}

func NewLensKitRepository(eng fwdb.RelationalEngine) *LensKitRepository {
	r := &LensKitRepository{
		BaseAggregateRepository: read.NewBaseAggregateRepository[*qadomain.LensKit](
			eng, func() *qadomain.LensKit { return &qadomain.LensKit{} },
		),
	}
	r.WithSchema(LensKitSchema())
	return r
}

var _ persistence.ScopedRepository[*qadomain.LensKit] = (*LensKitRepository)(nil)

type LensPartRepository struct {
	read.BaseAggregateRepository[*qadomain.LensPart]
}

func NewLensPartRepository(eng fwdb.RelationalEngine) *LensPartRepository {
	r := &LensPartRepository{
		BaseAggregateRepository: read.NewBaseAggregateRepository[*qadomain.LensPart](
			eng, func() *qadomain.LensPart { return &qadomain.LensPart{} },
		),
	}
	r.WithSchema(LensPartSchema())
	return r
}

var _ persistence.ScopedRepository[*qadomain.LensPart] = (*LensPartRepository)(nil)

// ProvisionLensTables creates qa_lens_kits + qa_lens_parts if absent,
// dialect-aware (idempotent, engine side-channel, no migration files). kit_id
// and gadget_id are nullable and carry NO database-level foreign key: the
// suite must be able to point a part at a hard-deleted gadget to exercise the
// dead-reference contract.
func ProvisionLensTables(ctx context.Context, eng fwdb.RelationalEngine) error {
	postgres := eng.Dialect().Placeholder(1) == "$1"

	var brands, kits, parts string
	if postgres {
		brands = `CREATE TABLE IF NOT EXISTS qa_lens_brands (
			id          UUID         PRIMARY KEY,
			revision    BIGINT       NOT NULL DEFAULT 0,
			name        VARCHAR(255) NOT NULL,
			deleted_at  TIMESTAMP,
			created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
		kits = `CREATE TABLE IF NOT EXISTS qa_lens_kits (
			id          UUID         PRIMARY KEY,
			revision    BIGINT       NOT NULL DEFAULT 0,
			name        VARCHAR(255) NOT NULL,
			deleted_at  TIMESTAMP,
			created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
		parts = `CREATE TABLE IF NOT EXISTS qa_lens_parts (
			id          UUID         PRIMARY KEY,
			revision    BIGINT       NOT NULL DEFAULT 0,
			kit_id      VARCHAR(36),
			gadget_id   VARCHAR(36),
			brand_id    VARCHAR(36),
			label       VARCHAR(255) NOT NULL,
			slot        INT          NOT NULL DEFAULT 0,
			deleted_at  TIMESTAMP,
			created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
	} else {
		brands = `CREATE TABLE IF NOT EXISTS qa_lens_brands (
			id          BINARY(16)   NOT NULL,
			revision    BIGINT       NOT NULL DEFAULT 0,
			name        VARCHAR(255) NOT NULL,
			deleted_at  DATETIME     NULL,
			created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id)
		)`
		kits = `CREATE TABLE IF NOT EXISTS qa_lens_kits (
			id          BINARY(16)   NOT NULL,
			revision    BIGINT       NOT NULL DEFAULT 0,
			name        VARCHAR(255) NOT NULL,
			deleted_at  DATETIME     NULL,
			created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id)
		)`
		parts = `CREATE TABLE IF NOT EXISTS qa_lens_parts (
			id          BINARY(16)   NOT NULL,
			revision    BIGINT       NOT NULL DEFAULT 0,
			kit_id      VARCHAR(36)  NULL,
			gadget_id   VARCHAR(36)  NULL,
			brand_id    VARCHAR(36)  NULL,
			label       VARCHAR(255) NOT NULL,
			slot        INT          NOT NULL DEFAULT 0,
			deleted_at  DATETIME     NULL,
			created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id)
		)`
	}
	return qaExecDDL(ctx, eng, brands, kits, parts)
}
