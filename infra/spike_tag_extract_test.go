//go:build spike

// Spike 4 — extraction of `db:"col"` tags via reflect, IGNORING embedded
// fields (AggregateRoot, BaseEntity). This is what the framework needs to do
// to generate explicit SELECT col1, col2, ...
//
// How to run:
//
//	go test -tags=spike -v ./infra -run Spike4
//
// Does not depend on Postgres.
package infra

import (
	"reflect"
	"testing"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// extractDBTags inspects T via reflection and returns the ordered list of
// columns declared via `db:"col"` tag. Skips:
//   - anonymous fields (embedded): AggregateRoot, BaseEntity, etc.
//   - fields without db tag (including "-")
//   - private fields (rt.Field(i).PkgPath != "")
//
// This is the CANDIDATE framework implementation — it lives here as a spike
// to validate the strategy before nailing it down in the API.
func extractDBTags(t reflect.Type) []string {
	if t.Kind() == reflect.Ptr {
		t = t.Elem()
	}
	if t.Kind() != reflect.Struct {
		return nil
	}
	var cols []string
	for i := 0; i < t.NumField(); i++ {
		f := t.Field(i)
		if f.Anonymous {
			// Embedded — we skip. AggregateRoot/BaseEntity do not contribute
			// their own columns; id/timestamps are handled by the framework
			// (managed columns), not by the service's domain.
			continue
		}
		if f.PkgPath != "" {
			// Private field — ignore (pgx couldn't populate it anyway).
			continue
		}
		tag, ok := f.Tag.Lookup("db")
		if !ok || tag == "-" {
			continue
		}
		cols = append(cols, tag)
	}
	return cols
}

// Candidate structs — use db: tags on the existing fields.

type spike4UserWithTags struct {
	appdomain.User `db:"-"` // embedded but explicitly ignored
	Name           string   `db:"name"`
	Email          string   `db:"email"`
	CPF            string   `db:"cpf"`
	Phone          string   `db:"phone"`
}

// The real scenario: extract tags from appdomain.User WITHOUT it having tags
// today. Expected: empty list (because it isn't annotated yet).
func TestSpike4_ExtractTags_UserUntagged(t *testing.T) {
	cols := extractDBTags(reflect.TypeOf(appdomain.User{}))
	if len(cols) != 0 {
		t.Fatalf("expected empty (User has no tags), got: %v", cols)
	}
	t.Logf("OK — User still without tags → []. Adoption is opt-in.")
}

// Scenario after adoption: User decorated with db: tags must produce the
// correct list of columns, ignoring the AggregateRoot embed.
func TestSpike4_ExtractTags_UserWithTags(t *testing.T) {
	type taggedUser struct {
		Name  string `db:"name"`
		Email string `db:"email"`
		CPF   string `db:"cpf"`
		Phone string `db:"phone"`
	}
	cols := extractDBTags(reflect.TypeOf(taggedUser{}))
	expect := []string{"name", "email", "cpf", "phone"}
	if !reflect.DeepEqual(cols, expect) {
		t.Fatalf("expected %v, got %v", expect, cols)
	}
	t.Logf("OK — extraction: %v", cols)
}

// Aggregate scenario: struct with AggregateRoot embedded + tags on its own
// fields. The embed must NOT contribute columns (extractDBTags skips
// anonymous).
func TestSpike4_ExtractTags_AggregateRootEmbedded(t *testing.T) {
	type taggedAggregateRoot struct {
		appdomain.User        // embed of the real type, no tag (anonymous)
		ExtraField     string `db:"extra"`
	}
	cols := extractDBTags(reflect.TypeOf(taggedAggregateRoot{}))
	expect := []string{"extra"}
	if !reflect.DeepEqual(cols, expect) {
		t.Fatalf("expected %v (embed must be ignored), got %v", expect, cols)
	}
	t.Logf("OK — embed ignored, only own fields count: %v", cols)
}

// Address scenario (value type, 10 columns): after adopting the tags, the
// preserved order matches the field order.
func TestSpike4_ExtractTags_Address(t *testing.T) {
	type taggedAddress struct {
		ID           string `db:"id"`
		Label        string `db:"label"`
		Street       string `db:"street"`
		Number       string `db:"number"`
		Complement   string `db:"complement"`
		Neighborhood string `db:"neighborhood"`
		City         string `db:"city"`
		State        string `db:"state"`
		ZipCode      string `db:"zip_code"`
		Country      string `db:"country"`
	}
	cols := extractDBTags(reflect.TypeOf(taggedAddress{}))
	expect := []string{
		"id", "label", "street", "number", "complement",
		"neighborhood", "city", "state", "zip_code", "country",
	}
	if !reflect.DeepEqual(cols, expect) {
		t.Fatalf("incorrect order:\n  expected %v\n  got      %v", expect, cols)
	}
	t.Logf("OK — Address tags ordered: %v", cols)
}

// Sanity check: `db:"-"` tag skips the field (pgx/sqlx convention).
func TestSpike4_ExtractTags_SkipDash(t *testing.T) {
	type withSkip struct {
		Name   string `db:"name"`
		Secret string `db:"-"`
	}
	cols := extractDBTags(reflect.TypeOf(withSkip{}))
	if !reflect.DeepEqual(cols, []string{"name"}) {
		t.Fatalf("db:\"-\" did not skip: %v", cols)
	}
}
