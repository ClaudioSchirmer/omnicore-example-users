package infra

import (
	"testing"

	fwinfra "github.com/ClaudioSchirmer/omnicore/infra"
)

// UserView is the read-side projection consumed by /users GET endpoints.
// These tests lock the declarative artifacts the projection asks the
// framework to materialize on the Mongo cluster at boot:
//
//   - The "users" collection name (inferred from the Go type).
//   - The "addresses" EmbedMany inferred from User.AggregateChildren().
//   - The index set the read-side runtime depends on (TextIndex unlocks
//     `?search=` — without it, Mongo error 27 on the first request).
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
	if len(embeds) != 1 {
		t.Fatalf("embeds = %d, want 1 (addresses inferred from User.AggregateChildren)", len(embeds))
	}
}

func TestUserView_DeclaresExpectedIndexes(t *testing.T) {
	v := UserView()
	specs := v.IndexSpecs()
	if got, want := len(specs), 3; got != want {
		t.Fatalf("IndexSpecs len = %d, want %d", got, want)
	}

	// Asc index on email — lookup support for ?email=...
	if specs[0].Keys[0].Field != "email" || specs[0].Keys[0].Order != fwinfra.IndexOrderAsc {
		t.Errorf("specs[0] = %+v, want ascending index on email", specs[0].Keys)
	}

	// Desc index on created_at — sort support for ?sort=-created_at
	if specs[1].Keys[0].Field != "created_at" || specs[1].Keys[0].Order != fwinfra.IndexOrderDesc {
		t.Errorf("specs[1] = %+v, want descending index on created_at", specs[1].Keys)
	}

	// Text index — unlocks ?search= (Mongo $text requires it)
	if !specs[2].IsText() {
		t.Errorf("specs[2] = %+v, want TextIndex", specs[2].Keys)
	}
}

func TestUserView_PassesFrameworkValidation(t *testing.T) {
	if err := UserView().ValidateMongoSpec(); err != nil {
		t.Errorf("ValidateMongoSpec = %v, want nil", err)
	}
}
