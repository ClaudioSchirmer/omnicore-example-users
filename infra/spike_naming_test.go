//go:build spike

// Additional spike — discover EXACTLY how pgx resolves names (column → field)
// when there is no db tag. This decides whether tags are mandatory or
// optional in the final framework design.
package infra

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Scenario A — exact PascalCase (Name ↔ name): with lowercase, does it still
// match?
type pNameOnly struct {
	Name string
}

// Scenario B — real snake_case (ZipCode ↔ zip_code): what we saw in Spike 3.
type pSnakeCase struct {
	ZipCode string
}

// Scenario C — composite camelCase (zipCode in the DB ↔ ZipCode in Go).
type pCamelCase struct {
	ZipCode string
}

// Scenario D — uppercase acronym (URL ↔ url).
type pAcronym struct {
	URL string
}

// Scenario E — field with a name that doesn't follow any convention
// (postal_code_v2 ↔ PostalCodeV2): does it require an explicit tag?
type pWeird struct {
	PostalCodeV2 string
}

func TestSpikeNaming_PgxAutoMapping(t *testing.T) {
	pool := connect(t)
	defer pool.Close()
	ctx := context.Background()

	cases := []struct {
		name    string
		sql     string
		runFn   func(rows pgx.Rows) (any, error)
		getter  func(any) string
		want    string
		comment string
	}{
		{
			name: "lowercase_match",
			sql:  `SELECT 'john' AS name`,
			runFn: func(rows pgx.Rows) (any, error) {
				return pgx.CollectOneRow(rows, pgx.RowToAddrOfStructByName[pNameOnly])
			},
			getter:  func(v any) string { return v.(*pNameOnly).Name },
			want:    "john",
			comment: "Name (PascalCase) vs 'name' — expected match because pgx normalizes to lowercase",
		},
		{
			name: "snake_case_zip_code",
			sql:  `SELECT '50000000' AS zip_code`,
			runFn: func(rows pgx.Rows) (any, error) {
				return pgx.CollectOneRow(rows, pgx.RowToAddrOfStructByName[pSnakeCase])
			},
			getter:  func(v any) string { return v.(*pSnakeCase).ZipCode },
			want:    "50000000",
			comment: "ZipCode vs zip_code — confirm whether pgx strips _ or applies any snake normalization",
		},
		{
			name: "camel_case_in_db",
			sql:  `SELECT '50000000' AS "zipCode"`,
			runFn: func(rows pgx.Rows) (any, error) {
				return pgx.CollectOneRow(rows, pgx.RowToAddrOfStructByName[pCamelCase])
			},
			getter:  func(v any) string { return v.(*pCamelCase).ZipCode },
			want:    "50000000",
			comment: "ZipCode vs quoted zipCode (case-sensitive PG) — check tolerance",
		},
		{
			name: "uppercase_acronym",
			sql:  `SELECT '123' AS url`,
			runFn: func(rows pgx.Rows) (any, error) {
				return pgx.CollectOneRow(rows, pgx.RowToAddrOfStructByName[pAcronym])
			},
			getter:  func(v any) string { return v.(*pAcronym).URL },
			want:    "123",
			comment: "URL (acronym) vs url",
		},
		{
			name: "weird_naming",
			sql:  `SELECT '999' AS postal_code_v2`,
			runFn: func(rows pgx.Rows) (any, error) {
				return pgx.CollectOneRow(rows, pgx.RowToAddrOfStructByName[pWeird])
			},
			getter:  func(v any) string { return v.(*pWeird).PostalCodeV2 },
			want:    "999",
			comment: "PostalCodeV2 vs postal_code_v2 — non-trivial naming",
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rows, err := pool.Query(ctx, c.sql)
			if err != nil {
				t.Fatalf("query: %v", err)
			}
			res, err := c.runFn(rows)
			if err != nil {
				t.Logf("FAILED (%s): %v — IMPLICATION: needs an explicit tag", c.comment, err)
				t.Fail()
				return
			}
			got := c.getter(res)
			if got != c.want {
				t.Logf("WRONG VALUE (%s): got %q, want %q", c.comment, got, c.want)
				t.Fail()
				return
			}
			t.Logf("OK (%s) → %q", c.comment, got)
		})
	}
}
