//go:build qa

// This file owns the relational + read-side wiring for the QA-only Widget
// aggregate: a normal aggregate with a native child array AND two flat sibling
// facets (root + child-level), plus its Mongo view and the RelationalSource twin.
// It is the fixture behind the `relational_view` suite's child/sibling 4xx cases:
// the Mongo view row-selects on child/sibling fields, the relational twin rejects
// them 400. Self-provisions its four tables (no migration file). All gated behind
// the `qa` build tag.
package qafixtures

import (
	"context"

	"github.com/ClaudioSchirmer/omnicore/infra/db/command/read"
	fwdb "github.com/ClaudioSchirmer/omnicore/infra/db/core"
	"github.com/ClaudioSchirmer/omnicore/infra/db/query"

	qadomain "github.com/ClaudioSchirmer/omnicore-example-users/internal/domain/qafixtures"
)

// WidgetSchema maps the Widget aggregate across FOUR tables: the qa_widgets root,
// the qa_widget_specs root sibling (Material, 1:1 on the root id), and the
// qa_widget_parts child — itself carrying the qa_widget_part_tags child-level
// sibling (Tag, 1:1 on the child id).
func WidgetSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[*qadomain.Widget]("qa_widgets").
		ID("id").
		Revision("revision").
		Field("Name", "name").
		DeletedAt("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at").
		Sibling(fwdb.NewSiblingSchema[*qadomain.Widget]("qa_widget_specs").
			Field("Material", "material")).
		Child(WidgetPartSchema())
}

// WidgetPartSchema is the native child: ParentID widget_id back to the root, its
// own Label/Slot, and the child-level sibling qa_widget_part_tags (Tag).
func WidgetPartSchema() *fwdb.TableSchema {
	return fwdb.NewTableSchema[qadomain.WidgetPart]("qa_widget_parts").
		ID("id").
		ParentID("widget_id").
		Field("Label", "label").
		Field("Slot", "slot").
		DeletedAt("deleted_at").
		CreatedAt("created_at").
		UpdatedAt("updated_at").
		Sibling(fwdb.NewSiblingSchema[qadomain.WidgetPart]("qa_widget_part_tags").
			Field("Tag", "tag"))
}

// WidgetView is the normal Mongo projection: the flat widget + its Material
// sibling flat + the WidgetParts child array (each element carrying its Tag
// sibling flat). Row-selects on child/sibling fields via the DTO's nested filters.
func WidgetView() *query.ViewDefinition {
	return query.View("qa_widgets_view").
		Version(1).
		Schema(WidgetSchema()).
		Indexes(query.Index("name"))
}

// WidgetRelView is the RelationalSource twin over the SAME qa_widgets root,
// served through the widget repository's loader (passed in — one loader per
// aggregate, shared with the repo). Root (Name) reads reach parity with the Mongo
// view; a filter/sort on Material, WidgetParts.label or WidgetParts.tag is
// rejected 400 by the reader's root-own-column guard.
func WidgetRelView(loader query.RelationalReader) *query.ViewDefinition {
	return query.View("qa_widgets_view_rel").
		Version(1).
		Schema(WidgetSchema()).
		RelationalSource(loader)
}

// WidgetRepository is the flat aggregate-aware repository for Widget.
type WidgetRepository struct {
	read.BaseAggregateRepository[*qadomain.Widget]
}

func NewWidgetRepository(eng fwdb.RelationalEngine) *WidgetRepository {
	r := &WidgetRepository{
		BaseAggregateRepository: read.NewBaseAggregateRepository[*qadomain.Widget](
			eng, func() *qadomain.Widget { return &qadomain.Widget{} },
		),
	}
	r.WithSchema(WidgetSchema())
	return r
}

// ProvisionWidgetTables creates the four Widget tables if absent, dialect-aware
// via qaExecDDL (postgres + mysql hand-written, sqlserver + oracle derived). The
// two sibling tables borrow their owner's id as their PK/FK (ON DELETE CASCADE),
// exactly like the canonical employee_bank_accounts / dependent_health_plans
// siblings.
func ProvisionWidgetTables(ctx context.Context, eng fwdb.RelationalEngine) error {
	postgres := eng.Dialect().Placeholder(1) == "$1"

	var widgets, specs, parts, tags string
	if postgres {
		widgets = `CREATE TABLE IF NOT EXISTS qa_widgets (
			id          UUID         PRIMARY KEY,
			revision    BIGINT       NOT NULL DEFAULT 0,
			name        VARCHAR(255) NOT NULL,
			deleted_at  TIMESTAMP,
			created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
		specs = `CREATE TABLE IF NOT EXISTS qa_widget_specs (
			id          UUID         PRIMARY KEY REFERENCES qa_widgets (id) ON DELETE CASCADE,
			material    VARCHAR(128)
		)`
		parts = `CREATE TABLE IF NOT EXISTS qa_widget_parts (
			id          UUID         PRIMARY KEY,
			widget_id   UUID         NOT NULL REFERENCES qa_widgets (id) ON DELETE CASCADE,
			label       VARCHAR(255) NOT NULL,
			slot        INT          NOT NULL DEFAULT 0,
			deleted_at  TIMESTAMP,
			created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
			updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
		)`
		tags = `CREATE TABLE IF NOT EXISTS qa_widget_part_tags (
			id          UUID         PRIMARY KEY REFERENCES qa_widget_parts (id) ON DELETE CASCADE,
			tag         VARCHAR(128)
		)`
	} else {
		widgets = `CREATE TABLE IF NOT EXISTS qa_widgets (
			id          BINARY(16)   NOT NULL,
			revision    BIGINT       NOT NULL DEFAULT 0,
			name        VARCHAR(255) NOT NULL,
			deleted_at  DATETIME     NULL,
			created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id)
		)`
		specs = `CREATE TABLE IF NOT EXISTS qa_widget_specs (
			id          BINARY(16)   NOT NULL,
			material    VARCHAR(128) NULL,
			PRIMARY KEY (id),
			FOREIGN KEY (id) REFERENCES qa_widgets (id) ON DELETE CASCADE
		)`
		parts = `CREATE TABLE IF NOT EXISTS qa_widget_parts (
			id          BINARY(16)   NOT NULL,
			widget_id   BINARY(16)   NOT NULL,
			label       VARCHAR(255) NOT NULL,
			slot        INT          NOT NULL DEFAULT 0,
			deleted_at  DATETIME     NULL,
			created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
			PRIMARY KEY (id),
			FOREIGN KEY (widget_id) REFERENCES qa_widgets (id) ON DELETE CASCADE
		)`
		tags = `CREATE TABLE IF NOT EXISTS qa_widget_part_tags (
			id          BINARY(16)   NOT NULL,
			tag         VARCHAR(128) NULL,
			PRIMARY KEY (id),
			FOREIGN KEY (id) REFERENCES qa_widget_parts (id) ON DELETE CASCADE
		)`
	}

	return qaExecDDL(ctx, eng, widgets, specs, parts, tags)
}
