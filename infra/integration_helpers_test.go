//go:build integration

// Dialect-driven integration harness for omnicore-example-users/infra.
//
// The harness names no backend. It reads the configured dialect from the
// service YAML (database.dialect) and the connection string from DATABASE_URL —
// the same variable the YAML DSN interpolates — then builds the engine through
// the neutral core.NewEngine and runs every test against it. The test bodies
// assert through the backend-neutral repository API, so the SAME suite runs
// against whatever relational backend the project is configured for: a
// microservice is one backend, chosen in the YAML.
//
// Preconditions: the configured database must be reachable and already migrated
// (the service applies its migrations at boot via migrations.autoRun — point
// DATABASE_URL at that database, or at a disposable one migrated the same way).
// Each test resets the domain tables first via neutral SQL, so it starts from a
// known-empty state. Without DATABASE_URL the suite skips.
//
// Run:
//
//	DATABASE_URL=... go test -tags=integration ./infra/...
package infra

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/ClaudioSchirmer/omnicore/bootstrap"
	"github.com/ClaudioSchirmer/omnicore/infra/db/core"
)

// newTestEngine connects to the configured relational backend and returns the
// neutral engine the repositories run on, plus a cleanup that resets state and
// closes the engine.
func newTestEngine(t *testing.T) (core.RelationalEngine, func()) {
	t.Helper()

	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Skip("set DATABASE_URL to the configured database to run the integration suite")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	eng, err := core.NewEngine(configuredDialect(t), ctx, dsn, false)
	if err != nil {
		t.Skipf("cannot build the engine for the configured dialect: %v", err)
	}

	resetState(t, eng)
	return eng, func() {
		resetState(t, eng)
		eng.Close()
	}
}

// configuredDialect reads relational.dialect from the service YAML the same way
// the service does, so the test follows the project's configuration.
func configuredDialect(t *testing.T) string {
	t.Helper()
	profile := os.Getenv("APP_PROFILE")
	if profile == "" {
		profile = "dev"
	}
	path := filepath.Join(moduleRoot(t), fmt.Sprintf("microservice.%s.yaml", profile))
	cfg, err := bootstrap.LoadConfigFrom(path)
	if err != nil {
		t.Skipf("cannot load service config %s: %v", path, err)
	}
	return cfg.Relational.Dialect
}

// moduleRoot walks up from the test's working directory to the directory that
// holds go.mod, so the YAML resolves regardless of the package the test runs in.
func moduleRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Skipf("cannot resolve working directory: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Skip("module root (go.mod) not found from the test working directory")
		}
		dir = parent
	}
}

// resetState empties the domain tables via neutral SQL so each test starts from
// a known-empty state. The DELETE order respects the addresses→users FK; the
// engine's Querier runs the statements through whatever driver the dialect uses.
// A failure here means the configured database is unreachable or not migrated.
func resetState(t *testing.T, eng core.RelationalEngine) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	q := eng.Querier()
	for _, table := range []string{"addresses", "users", "outbox"} {
		if err := q.Exec(ctx, "DELETE FROM "+table); err != nil {
			t.Skipf("cannot reset the configured database (reachable and migrated?): %v", err)
		}
	}
}

func ptr(s string) *string { return &s }
