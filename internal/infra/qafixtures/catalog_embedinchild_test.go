//go:build qa

package qafixtures

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
)

// TestCatalogView_EmbedInChildValidatesAtBoot proves the qa_catalog_view — now
// carrying an EmbedInChild on the native CatalogLine child — passes the boot
// validation: the enriched schema IS a native child, the source is external,
// and the required covering multikey index ("CatalogLines.item_id") is declared
// (so the derived child segment name matches the declared index).
func TestCatalogView_EmbedInChildValidatesAtBoot(t *testing.T) {
	if err := query.ValidateViewSchemas([]*query.ViewDefinition{CatalogView()}); err != nil {
		t.Fatalf("qa_catalog_view with EmbedInChild must validate at boot, got: %v", err)
	}
}

// TestCatalogView_BuildViewNodeHasEnrichedSegment proves the read-side node
// registers the enriched "Item" segment INSIDE the CatalogLines child node, so
// the Result fill / ?fields= / filter can reach catalogLines.item.
func TestCatalogView_BuildViewNodeHasEnrichedSegment(t *testing.T) {
	node := CatalogView().BuildViewNode()
	// ColumnPath resolves a Go field path to the physical doc path; a path into
	// the enriched child segment must resolve once the node knows it.
	cols, ok := node.ColumnPath([]string{"CatalogLines", "Item", "Label"})
	if !ok || len(cols) == 0 {
		t.Fatalf("read-side node must resolve the enriched child path CatalogLines.Item.Label; got %v (ok=%v)", cols, ok)
	}
}

// TestCatalogView_BuildViewNodeEnrichedColumn asserts the resolved physical path
// keys the enriched sub-doc by its doc field ("item") and the column ("label").
func TestCatalogView_BuildViewNodeEnrichedColumn(t *testing.T) {
	node := CatalogView().BuildViewNode()
	cols, ok := node.ColumnPath([]string{"CatalogLines", "Item", "Label"})
	if !ok {
		t.Fatalf("path did not resolve")
	}
	want := []string{"CatalogLines", "item", "label"}
	if len(cols) != len(want) {
		t.Fatalf("got %v, want %v", cols, want)
	}
	for i := range want {
		if cols[i] != want[i] {
			t.Fatalf("got %v, want %v", cols, want)
		}
	}
}

// TestAccountView_EmbedInChildValidatesAtBoot proves the SharedBaseView variant
// — EmbedInChild on the BASE's native child (AccountLine) — passes boot
// validation (native base-child + external source + the required multikey index).
func TestAccountView_EmbedInChildValidatesAtBoot(t *testing.T) {
	if err := query.ValidateViewSchemas([]*query.ViewDefinition{AccountView()}); err != nil {
		t.Fatalf("qa_accounts_view with EmbedInChild on a base child must validate, got: %v", err)
	}
}

// TestAccountView_BuildViewNodeHasEnrichedSegment proves the read-side node
// resolves the enriched base-child path on a SharedBaseView.
func TestAccountView_BuildViewNodeHasEnrichedSegment(t *testing.T) {
	cols, ok := AccountView().BuildViewNode().ColumnPath([]string{"AccountLines", "Item", "Label"})
	if !ok || len(cols) == 0 {
		t.Fatalf("read-side node must resolve AccountLines.Item.Label on the SharedBaseView; got %v (ok=%v)", cols, ok)
	}
}

// TestGadgetKitView_EmbedInChildValidatesAtBoot proves the upstream_gadgets
// EmbedInChild fixture (a fresh aggregate, not touching GadgetSchema) validates
// at boot and its read-side node resolves the enriched path.
func TestGadgetKitView_EmbedInChildValidatesAtBoot(t *testing.T) {
	if err := query.ValidateViewSchemas([]*query.ViewDefinition{GadgetKitView()}); err != nil {
		t.Fatalf("qa_gadget_kits_view with EmbedInChild over upstream_gadgets must validate, got: %v", err)
	}
	cols, ok := GadgetKitView().BuildViewNode().ColumnPath([]string{"GadgetKitLines", "Gadget", "Name"})
	if !ok || len(cols) == 0 {
		t.Fatalf("read-side node must resolve GadgetKitLines.Gadget.Name; got %v (ok=%v)", cols, ok)
	}
}
