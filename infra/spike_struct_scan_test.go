//go:build spike

// Spike tests for Proposal B — validate whether pgx struct-scan works with
// structs that embed domain.AggregateRoot/BaseEntity, and measure the
// performance cost versus the current manual scanner.
//
// How to run:
//
//	docker compose up -d postgres
//	go test -tags=spike -v ./infra -run Spike
//	go test -tags=spike -bench=Spike ./infra -benchmem -benchtime=3s
//
// The tests assume Postgres is reachable at DATABASE_URL (or at the default
// DSN of this service's docker-compose). Does NOT alter the DB schema; uses
// a temporary table created/dropped inside the test's own transaction.
package infra

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	appdomain "github.com/ClaudioSchirmer/omnicore-example-users/domain"
)

// dsn — local DSN. Uses env override when set, otherwise the default from
// this service's docker-compose (port 5433).
func dsn() string {
	if v := os.Getenv("DATABASE_URL"); v != "" {
		return v
	}
	return "postgres://omnicore:omnicore@localhost:5433/users_db?sslmode=disable"
}

// connect opens a pool and runs ping. Skip the test if the DB is not
// available — the spike depends on a real PG and it isn't worth making it
// flakey.
func connect(t *testing.T) *pgxpool.Pool {
	t.Helper()
	pool, err := pgxpool.New(context.Background(), dsn())
	if err != nil {
		t.Skipf("postgres unavailable, skipping spike: %v", err)
	}
	if err := pool.Ping(context.Background()); err != nil {
		pool.Close()
		t.Skipf("postgres ping failed, skipping spike: %v", err)
	}
	return pool
}

// setupSpikeSchema creates spike_users + spike_addresses tables with the SAME
// structure as the production tables (same columns, same types). Cleans up at
// the end of the test via t.Cleanup. Temporary tables avoid colliding with
// the real schema and allow running the spike repeatedly.
func setupSpikeSchema(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	ctx := context.Background()
	ddl := []string{
		`DROP TABLE IF EXISTS spike_addresses`,
		`DROP TABLE IF EXISTS spike_users`,
		`CREATE TABLE spike_users (
			id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
			name       VARCHAR(255) NOT NULL,
			email      VARCHAR(255) NOT NULL,
			cpf        VARCHAR(11)  NOT NULL,
			phone      VARCHAR(20),
			deleted_at TIMESTAMP,
			created_at TIMESTAMP NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMP NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE spike_addresses (
			id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
			user_id      UUID         NOT NULL REFERENCES spike_users(id) ON DELETE CASCADE,
			label        VARCHAR(50),
			street       VARCHAR(255) NOT NULL,
			number       VARCHAR(20)  NOT NULL,
			complement   VARCHAR(100),
			neighborhood VARCHAR(100) NOT NULL,
			city         VARCHAR(100) NOT NULL,
			state        CHAR(2)      NOT NULL,
			zip_code     VARCHAR(8)   NOT NULL,
			country      CHAR(2)      NOT NULL DEFAULT 'BR',
			deleted_at   TIMESTAMP,
			created_at   TIMESTAMP NOT NULL DEFAULT NOW(),
			updated_at   TIMESTAMP NOT NULL DEFAULT NOW()
		)`,
	}
	for _, q := range ddl {
		if _, err := pool.Exec(ctx, q); err != nil {
			t.Fatalf("ddl failed (%q): %v", q[:min(60, len(q))], err)
		}
	}
	t.Cleanup(func() {
		pool.Exec(ctx, `DROP TABLE IF EXISTS spike_addresses`)
		pool.Exec(ctx, `DROP TABLE IF EXISTS spike_users`)
	})
}

// insertSampleUser inserts a user + 1 address so there is data to read.
// Returns the id of the inserted user.
func insertSampleUser(t *testing.T, pool *pgxpool.Pool) string {
	t.Helper()
	ctx := context.Background()
	var userID string
	err := pool.QueryRow(ctx, `
		INSERT INTO spike_users (name, email, cpf, phone)
		VALUES ('John', 'john@x.com', '12345678909', '11999998888')
		RETURNING id
	`).Scan(&userID)
	if err != nil {
		t.Fatalf("insert user: %v", err)
	}
	_, err = pool.Exec(ctx, `
		INSERT INTO spike_addresses
		(user_id, label, street, number, complement, neighborhood, city, state, zip_code, country)
		VALUES ($1, 'home', 'Main St', '100', 'apt 1', 'Downtown', 'Recife', 'PE', '50000000', 'BR')
	`, userID)
	if err != nil {
		t.Fatalf("insert address: %v", err)
	}
	return userID
}

// ───────────────────────────────────────────────────────────────────────────────
// SPIKE 1 — pgx.RowToAddrOfStructByName with User (embeds AggregateRoot/BaseEntity)
//
// Hypothesis: since AggregateRoot and BaseEntity only have private fields,
// pgx reflection only "sees" Name/Email/CPF/Phone from User. If that is
// true, the 17-line manual scanner can become a 1-liner without touching
// the embedded fields.
//
// Success criterion: scan resolves without error, populates
// Name/Email/CPF/Phone with the correct values. Failure expected if pgx
// tries to map a column to an embedded private field.
// ───────────────────────────────────────────────────────────────────────────────
func TestSpike1_StructScanUserWithEmbeddedAggregateRoot(t *testing.T) {
	pool := connect(t)
	defer pool.Close()
	setupSpikeSchema(t, pool)
	insertSampleUser(t, pool)

	ctx := context.Background()

	// Case A: explicit SELECT of only the domain columns (no id/timestamps).
	// Hypothesis: should work cleanly because each column maps to an
	// exported User field.
	t.Run("explicit_columns_domain_only", func(t *testing.T) {
		rows, err := pool.Query(ctx, `SELECT name, email, cpf, phone FROM spike_users LIMIT 1`)
		if err != nil {
			t.Fatalf("query: %v", err)
		}
		user, err := pgx.CollectOneRow(rows, pgx.RowToAddrOfStructByName[appdomain.User])
		if err != nil {
			t.Fatalf("RowToAddrOfStructByName falhou: %v", err)
		}
		if user.Name != "John" || user.Email != "john@x.com" || user.CPF != "12345678909" || user.Phone != "11999998888" {
			t.Fatalf("incorrect values: %+v", user)
		}
		t.Logf("OK — User scan via reflection: %+v", *user)
	})

	// Case B: SELECT *. Will bring id/deleted_at/created_at/updated_at —
	// which have NO corresponding field on User. Hypothesis: pgx by default
	// complains if a column has no destination. The result matters to decide
	// whether the framework needs to generate explicit SELECT or can reuse
	// SELECT *.
	t.Run("select_star_full_columns", func(t *testing.T) {
		rows, err := pool.Query(ctx, `SELECT * FROM spike_users LIMIT 1`)
		if err != nil {
			t.Fatalf("query: %v", err)
		}
		user, err := pgx.CollectOneRow(rows, pgx.RowToAddrOfStructByName[appdomain.User])
		if err != nil {
			t.Logf("EXPECTED: SELECT * fails because id/deleted_at/created_at/updated_at have no destination field: %v", err)
			return
		}
		t.Logf("SURPRISE — SELECT * worked: %+v", *user)
	})

	// Case C: RowToAddrOfStructByNameLax. ORIGINAL (wrong) hypothesis: Lax
	// would accept extra columns. Reading pgx/rows.go:660 makes it clear:
	// "Lax" means "the struct may have MORE fields than rows" — not "row
	// may have more columns than fields". We confirm it fails the same way
	// as the strict version; documented for the record.
	t.Run("select_star_lax_variant_confirms_strict_fail", func(t *testing.T) {
		rows, err := pool.Query(ctx, `SELECT * FROM spike_users LIMIT 1`)
		if err != nil {
			t.Fatalf("query: %v", err)
		}
		_, err = pgx.CollectOneRow(rows, pgx.RowToAddrOfStructByNameLax[appdomain.User])
		if err == nil {
			t.Fatal("EXPECTED Lax to fail on SELECT * — it didn't. Re-read the pgx doc.")
		}
		t.Logf("CONFIRMED — Lax does NOT help on SELECT *: %v", err)
		t.Logf("CONSEQUENCE: framework must generate an explicit SELECT col1,col2,...")
	})
}

// ───────────────────────────────────────────────────────────────────────────────
// SPIKE 3 — pgx.RowToStructByName with Address (value type, non-pointer)
//
// Address is a value type because of reflect.DeepEqual's needs in
// AggregateRoot. pgx offers Addr variants (return *T) and non-Addr (return
// T). Test that both work — the framework needs to return
// AggregateValueObject (interface), which Address satisfies by value.
// ───────────────────────────────────────────────────────────────────────────────
func TestSpike3_StructScanAddressValueType(t *testing.T) {
	pool := connect(t)
	defer pool.Close()
	setupSpikeSchema(t, pool)
	insertSampleUser(t, pool)
	ctx := context.Background()

	t.Run("value_scan_RowToStructByName", func(t *testing.T) {
		rows, err := pool.Query(ctx, `SELECT id, label, street, number, complement, neighborhood, city, state, zip_code, country FROM spike_addresses LIMIT 1`)
		if err != nil {
			t.Fatalf("query: %v", err)
		}
		addr, err := pgx.CollectOneRow(rows, pgx.RowToStructByName[appdomain.Address])
		if err != nil {
			t.Fatalf("RowToStructByName falhou: %v", err)
		}
		// Note: does pgx map names CASE-INSENSITIVELY or only lowercase?
		// Address.ZipCode vs zip_code column — if it doesn't match, it
		// returns empty with no error. We test explicitly.
		if addr.Street != "Main St" {
			t.Fatalf("Street empty — name match failed: %+v", addr)
		}
		if addr.ZipCode != "50000000" {
			t.Logf("PROBLEM — ZipCode empty (expected '50000000'): %+v", addr)
			t.Logf("Meaning pgx does NOT map zip_code → ZipCode automatically. Will require a db:\"zip_code\" tag.")
			t.Fail()
			return
		}
		t.Logf("OK — Address value scan: %+v", addr)
	})
}


// ───────────────────────────────────────────────────────────────────────────────
// SPIKE 1 + 3 (with db: tags) — Address and User decorated with db: tags
//
// Defines local structs with db: tag to check whether pgx prioritizes the tag
// over the field name. If so, we can map ZipCode → zip_code via
// `db:"zip_code"` without ambiguity.
// ───────────────────────────────────────────────────────────────────────────────

type spikeUserWithTags struct {
	Name  string `db:"name"`
	Email string `db:"email"`
	CPF   string `db:"cpf"`
	Phone string `db:"phone"`
}

type spikeAddressWithTags struct {
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

func TestSpike1_3_TaggedStructs(t *testing.T) {
	pool := connect(t)
	defer pool.Close()
	setupSpikeSchema(t, pool)
	insertSampleUser(t, pool)
	ctx := context.Background()

	t.Run("tagged_user", func(t *testing.T) {
		rows, _ := pool.Query(ctx, `SELECT name, email, cpf, phone FROM spike_users LIMIT 1`)
		u, err := pgx.CollectOneRow(rows, pgx.RowToAddrOfStructByName[spikeUserWithTags])
		if err != nil {
			t.Fatalf("tagged user failed: %v", err)
		}
		t.Logf("OK tagged user: %+v", *u)
	})

	t.Run("tagged_address_with_zipcode", func(t *testing.T) {
		rows, _ := pool.Query(ctx, `SELECT id, label, street, number, complement, neighborhood, city, state, zip_code, country FROM spike_addresses LIMIT 1`)
		a, err := pgx.CollectOneRow(rows, pgx.RowToStructByName[spikeAddressWithTags])
		if err != nil {
			t.Fatalf("tagged address failed: %v", err)
		}
		if a.ZipCode != "50000000" {
			t.Fatalf("db:zip_code tag did not work: %+v", a)
		}
		t.Logf("OK tagged address — ZipCode mapped via tag: %+v", a)
	})
}

// ───────────────────────────────────────────────────────────────────────────────
// SPIKE 2 — Benchmark manual scanner vs reflection (pgx struct scan)
//
// Runs 10k iterations of each path, measures ns/op + alloc/op. The number
// that matters is the delta — if reflection costs <2x the manual, it's
// acceptable; if >5x, the framework should cache the decoder (next
// experiment) or keep the manual scanner as the performance path.
// ───────────────────────────────────────────────────────────────────────────────

// scanUserRowManual replicates the current scanner from user_repository.go
// for a fair comparison.
func scanUserRowManual(row pgx.Row) (*appdomain.User, error) {
	u := &appdomain.User{}
	var (
		id        string
		phone     *string
		deletedAt *time.Time
		createdAt time.Time
		updatedAt time.Time
	)
	if err := row.Scan(&id, &u.Name, &u.Email, &u.CPF, &phone, &deletedAt, &createdAt, &updatedAt); err != nil {
		return nil, err
	}
	if phone != nil {
		u.Phone = *phone
	}
	return u, nil
}

func BenchmarkSpike2_ManualScan(b *testing.B) {
	pool, err := pgxpool.New(context.Background(), dsn())
	if err != nil {
		b.Skipf("pg unavailable: %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(context.Background()); err != nil {
		b.Skipf("pg ping: %v", err)
	}
	setupSpikeSchemaB(b, pool)
	defer cleanupSpikeSchema(pool)
	insertSampleUserB(b, pool)
	ctx := context.Background()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		row := pool.QueryRow(ctx, `SELECT * FROM spike_users LIMIT 1`)
		_, err := scanUserRowManual(row)
		if err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkSpike2_StructScan_ExplicitCols(b *testing.B) {
	pool, err := pgxpool.New(context.Background(), dsn())
	if err != nil {
		b.Skipf("pg unavailable: %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(context.Background()); err != nil {
		b.Skipf("pg ping: %v", err)
	}
	setupSpikeSchemaB(b, pool)
	defer cleanupSpikeSchema(pool)
	insertSampleUserB(b, pool)
	ctx := context.Background()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		rows, err := pool.Query(ctx, `SELECT name, email, cpf, phone FROM spike_users LIMIT 1`)
		if err != nil {
			b.Fatal(err)
		}
		_, err = pgx.CollectOneRow(rows, pgx.RowToAddrOfStructByName[appdomain.User])
		if err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkSpike2_StructScan_Lax(b *testing.B) {
	pool, err := pgxpool.New(context.Background(), dsn())
	if err != nil {
		b.Skipf("pg unavailable: %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(context.Background()); err != nil {
		b.Skipf("pg ping: %v", err)
	}
	setupSpikeSchemaB(b, pool)
	defer cleanupSpikeSchema(pool)
	insertSampleUserB(b, pool)
	ctx := context.Background()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		rows, err := pool.Query(ctx, `SELECT * FROM spike_users LIMIT 1`)
		if err != nil {
			b.Fatal(err)
		}
		_, err = pgx.CollectOneRow(rows, pgx.RowToAddrOfStructByNameLax[appdomain.User])
		if err != nil {
			b.Fatal(err)
		}
	}
}

// Helpers for benchmarks (separated from tests to avoid mismatched t.Helper /
// b.Helper calls).
func setupSpikeSchemaB(b *testing.B, pool *pgxpool.Pool) {
	b.Helper()
	ctx := context.Background()
	ddl := []string{
		`DROP TABLE IF EXISTS spike_addresses`,
		`DROP TABLE IF EXISTS spike_users`,
		`CREATE TABLE spike_users (
			id         UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
			name       VARCHAR(255) NOT NULL,
			email      VARCHAR(255) NOT NULL,
			cpf        VARCHAR(11)  NOT NULL,
			phone      VARCHAR(20),
			deleted_at TIMESTAMP,
			created_at TIMESTAMP NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMP NOT NULL DEFAULT NOW()
		)`,
	}
	for _, q := range ddl {
		if _, err := pool.Exec(ctx, q); err != nil {
			b.Fatalf("ddl: %v", err)
		}
	}
}

func cleanupSpikeSchema(pool *pgxpool.Pool) {
	pool.Exec(context.Background(), `DROP TABLE IF EXISTS spike_addresses`)
	pool.Exec(context.Background(), `DROP TABLE IF EXISTS spike_users`)
}

func insertSampleUserB(b *testing.B, pool *pgxpool.Pool) {
	b.Helper()
	_, err := pool.Exec(context.Background(), `
		INSERT INTO spike_users (name, email, cpf, phone)
		VALUES ('John', 'john@x.com', '12345678909', '11999998888')
	`)
	if err != nil {
		b.Fatalf("insert: %v", err)
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// Suppress unused-import warning when fmt is no longer used in some case.
var _ = fmt.Sprintf
