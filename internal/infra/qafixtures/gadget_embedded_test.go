//go:build qa

package qafixtures

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
)

// These tests lock the declarative artifacts of the embedded gadget view — the
// read surface that turns the upstream_gadgets projection into something served
// through a ViewReader endpoint instead of Mongo-only. The boot-side IO
// (createCollection / ripple round-trips) is covered by qa/upstream_composition.sh
// once docker-compose is up; the declaration is what stays locked here.

func TestGadgetEmbeddedView_ShapeAndEmbed(t *testing.T) {
	v := GadgetEmbeddedView()
	if v.Name() != "gadgets_embedded" {
		t.Errorf("Name = %q, want %q", v.Name(), "gadgets_embedded")
	}
	if v.RootTable() != "gadgets" {
		t.Errorf("RootTable = %q, want %q", v.RootTable(), "gadgets")
	}
	embeds := v.Embeds()
	if len(embeds) != 1 {
		t.Fatalf("embeds = %d, want 1 (the one-to-one upstream mirror)", len(embeds))
	}
	e := embeds[0]
	if e.Field() != "upstreamMirror" {
		t.Errorf("embed field = %q, want %q", e.Field(), "upstreamMirror")
	}
	if e.Many() {
		t.Error("embed Many = true, want false (one-to-one Embed, not EmbedMany)")
	}
	src := e.Source()
	if !src.IsMongo() {
		t.Error("embed source IsMongo = false, want true (external upstream projection)")
	}
	if src.Collection() != "upstream_gadgets" {
		t.Errorf("embed collection = %q, want %q", src.Collection(), "upstream_gadgets")
	}
	// One-to-one joins on the parent-side .On column (gadget.id → mirror _id).
	if src.JoinKey() != "id" {
		t.Errorf("embed join key (.On) = %q, want %q", src.JoinKey(), "id")
	}
}

// TestGadgetEmbeddedView_CoversJoinFieldIndex mirrors the §8.1 boot guard: an
// external Mongo embed must have a covering index whose FIRST key is the join
// field. Without query.Index("id") the framework would abort boot.
func TestGadgetEmbeddedView_CoversJoinFieldIndex(t *testing.T) {
	v := GadgetEmbeddedView()
	for _, idx := range v.IndexSpecs() {
		keys := idx.KeyNames()
		if len(keys) > 0 && keys[0] == "id" {
			return
		}
	}
	t.Error(`no covering index whose first key is the join field "id" — §8.1 boot guard would reject the view`)
}

// TestGadgetEmbeddedView_SchemasValidate runs the same completeness check the
// framework runs at boot: root schema + every embed declares a TableSchema, PK,
// join key, and (for external embeds) a Go segment via .As.
func TestGadgetEmbeddedView_SchemasValidate(t *testing.T) {
	if err := query.ValidateViewSchemas([]*query.ViewDefinition{GadgetEmbeddedView()}); err != nil {
		t.Fatalf("ValidateViewSchemas: %v", err)
	}
}

func TestGadgetUpstreamMirrorSchema_External(t *testing.T) {
	s := GadgetUpstreamMirrorSchema()
	if !s.IsExternal() {
		t.Error("IsExternal = false, want true (type-less upstream schema)")
	}
	if s.Table() != "upstream_gadgets" {
		t.Errorf("Table = %q, want %q", s.Table(), "upstream_gadgets")
	}
	if !s.HasPKDeclared() {
		t.Error("HasPKDeclared = false, want true (PK(\"id\"))")
	}
}
