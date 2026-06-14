//go:build integration

// Integration test helpers for omnicore-example-users/infra. Defaults target
// the local docker-compose Postgres (omnicore:omnicore@localhost:5433). Each
// test creates a throw-away database, applies the service's domain schema
// + the framework's outbox table, and tears it down on cleanup.
//
// Run with:
//
//	go test -tags=integration ./infra/...
//
// Override via OMNICORE_TEST_PG_DSN when the bench listens elsewhere.
package infra

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	fwinfra "github.com/ClaudioSchirmer/omnicore/infra"
)

const defaultPGAdminDSN = "postgres://omnicore:omnicore@localhost:5433/postgres?sslmode=disable"

func pgAdminDSN() string {
	if v := os.Getenv("OMNICORE_TEST_PG_DSN"); v != "" {
		return v
	}
	return defaultPGAdminDSN
}

// newTestPG provisions a throw-away PG database with the framework outbox
// + the service's users/addresses tables already applied. Returns a
// *fwinfra.Postgres + cleanup func that drops the database.
func newTestPG(t *testing.T) (*fwinfra.Postgres, func()) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	dbName := fmt.Sprintf("example_users_test_%s", strings.ReplaceAll(uuid.NewString(), "-", ""))

	adminPool, err := pgxpool.New(ctx, pgAdminDSN())
	if err != nil {
		t.Skipf("skipping integration test: cannot reach Postgres at %s (%v)", pgAdminDSN(), err)
	}
	defer adminPool.Close()

	if _, err := adminPool.Exec(ctx, fmt.Sprintf(`CREATE DATABASE %q`, dbName)); err != nil {
		t.Fatalf("CREATE DATABASE %q: %v", dbName, err)
	}

	dsn := swapDB(pgAdminDSN(), dbName)
	pg, err := fwinfra.NewPostgres(ctx, dsn)
	if err != nil {
		_, _ = adminPool.Exec(ctx, fmt.Sprintf(`DROP DATABASE IF EXISTS %q`, dbName))
		t.Fatalf("NewPostgres: %v", err)
	}

	if err := installSchema(ctx, pg.Pool()); err != nil {
		pg.Close()
		_, _ = adminPool.Exec(ctx, fmt.Sprintf(`DROP DATABASE IF EXISTS %q`, dbName))
		t.Fatalf("install schema: %v", err)
	}

	cleanup := func() {
		pg.Close()
		c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		admin, err := pgxpool.New(c, pgAdminDSN())
		if err != nil {
			return
		}
		defer admin.Close()
		_, _ = admin.Exec(c, `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()`, dbName)
		_, _ = admin.Exec(c, fmt.Sprintf(`DROP DATABASE IF EXISTS %q`, dbName))
	}
	return pg, cleanup
}

func swapDB(dsn, db string) string {
	idx := strings.LastIndex(dsn, "/")
	q := strings.Index(dsn, "?")
	if idx == -1 || q == -1 || q < idx {
		return dsn
	}
	return dsn[:idx+1] + db + dsn[q:]
}

// installSchema seeds the throw-away DB with everything the example's infra
// touches: framework outbox + the service's users/addresses tables (mirroring
// migrations/0002_init.up.sql). Inlined here to avoid pulling the migration
// package into the test.
func installSchema(ctx context.Context, pool *pgxpool.Pool) error {
	stmts := []string{
		`CREATE EXTENSION IF NOT EXISTS pgcrypto`,
		`CREATE TABLE outbox (
			id BIGSERIAL PRIMARY KEY,
			aggregate_type TEXT NOT NULL,
			aggregate_id TEXT NOT NULL,
			event_type TEXT NOT NULL,
			payload JSONB NOT NULL,
			created_at TIMESTAMP NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE users (
			id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
			name        VARCHAR(255) NOT NULL,
			email       VARCHAR(255) NOT NULL,
			phone       VARCHAR(20),
			deleted_at  TIMESTAMP,
			created_at  TIMESTAMP NOT NULL DEFAULT NOW(),
			updated_at  TIMESTAMP NOT NULL DEFAULT NOW()
		)`,
		`CREATE UNIQUE INDEX users_email_active_idx ON users (email) WHERE deleted_at IS NULL`,
		`CREATE TABLE addresses (
			id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
			user_id       UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
			label         VARCHAR(50),
			street        VARCHAR(255) NOT NULL,
			number        VARCHAR(20) NOT NULL,
			complement    VARCHAR(100),
			neighborhood  VARCHAR(100) NOT NULL,
			city          VARCHAR(100) NOT NULL,
			state         VARCHAR(50) NOT NULL,
			zip_code      VARCHAR(12) NOT NULL,
			country       CHAR(2) NOT NULL,
			deleted_at    TIMESTAMP,
			created_at    TIMESTAMP NOT NULL DEFAULT NOW(),
			updated_at    TIMESTAMP NOT NULL DEFAULT NOW()
		)`,
	}
	for _, s := range stmts {
		if _, err := pool.Exec(ctx, s); err != nil {
			return err
		}
	}
	return nil
}

func ptr(s string) *string { return &s }
