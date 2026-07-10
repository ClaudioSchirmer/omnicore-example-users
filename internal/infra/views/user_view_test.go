package views

import (
	"testing"

	"github.com/ClaudioSchirmer/omnicore/infra/db/query"
)

// UserView is the read-side projection consumed by /users GET endpoints.
// These tests lock the declarative artifacts the projection asks the
// framework to materialize on the Mongo cluster at boot:
//
//   - The "users" collection name (inferred from the Go type).
//   - No explicit EmbedMany: the addresses are the shared Person's base
//     children, composed automatically from the SharedBase schema, so the view
//     declares zero embeds (the "Addresses" segment is derived, not declared).
//   - The index set the read-side runtime depends on. Note document/email and
//     the (name,email) TextIndex are all SharedBase (person) columns merged
//     flat into the doc by the composer.
//
// The boot-side IO (createCollection / createIndex round-trips) is
// covered by the QA E2E suite once the docker-compose Mongo is up; the
// declaration is what stays locked here.

func TestUserView_CollectionNameAndEmbeds(t *testing.T) {
	v := UserView()
	if v.Name() != "users" {
		t.Errorf("Name = %q, want %q", v.Name(), "users")
	}
	if v.RootTable() != "users" {
		t.Errorf("RootTable = %q, want %q", v.RootTable(), "users")
	}
	embeds := v.Embeds()
	if len(embeds) != 0 {
		t.Fatalf("embeds = %d, want 0 (addresses are base-children, composed automatically)", len(embeds))
	}
}

func TestUserView_DeclaresExpectedIndexes(t *testing.T) {
	v := UserView()
	specs := v.IndexSpecs()
	if got, want := len(specs), 4; got != want {
		t.Fatalf("IndexSpecs len = %d, want %d", got, want)
	}

	// Asc index on document — the natural-key lookup that replaces email.
	if specs[0].Keys[0].Field != "document" || specs[0].Keys[0].Order != query.IndexOrderAsc {
		t.Errorf("specs[0] = %+v, want ascending index on document", specs[0].Keys)
	}

	// Asc index on email — lookup support for ?email=...
	if specs[1].Keys[0].Field != "email" || specs[1].Keys[0].Order != query.IndexOrderAsc {
		t.Errorf("specs[1] = %+v, want ascending index on email", specs[1].Keys)
	}

	// Desc index on created_at — sort support for ?sort=-created_at
	if specs[2].Keys[0].Field != "created_at" || specs[2].Keys[0].Order != query.IndexOrderDesc {
		t.Errorf("specs[2] = %+v, want descending index on created_at", specs[2].Keys)
	}

	// Text index — unlocks ?search= (Mongo $text requires it)
	if !specs[3].IsText() {
		t.Errorf("specs[3] = %+v, want TextIndex", specs[3].Keys)
	}
}

func TestUserView_PassesFrameworkValidation(t *testing.T) {
	if err := UserView().ValidateMongoSpec(); err != nil {
		t.Errorf("ValidateMongoSpec = %v, want nil", err)
	}
}
