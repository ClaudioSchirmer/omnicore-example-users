//go:build qa

package qafixtures

import (
	"context"
	"regexp"
	"strings"

	fwdb "github.com/ClaudioSchirmer/omnicore/infra/db/core"
)

// qaExecDDL executes each provisioning statement through the engine's neutral
// Querier, translating the MySQL-shaped DDL into T-SQL when the engine is SQL
// Server and into Oracle DDL when it is Oracle (detected the same way the
// provisioners pick their dialect branch — by the placeholder form). The QA
// fixtures deliberately keep TWO hand-written DDL flavors (postgres + mysql,
// the always-on lanes) and derive the others mechanically: the MySQL shapes
// already use BINARY(16)/VARCHAR/CURRENT_TIMESTAMP, so only a handful of
// idioms differ per target, all rewritten below. This is QA scaffolding — the
// canonical service keeps hand-written per-dialect migrations
// (migrations/{postgres,mysql,sqlserver,oracle}); never copy this translator
// into production code.
func qaExecDDL(ctx context.Context, eng fwdb.RelationalEngine, stmts ...string) error {
	var rewrite func(string) string
	switch eng.Dialect().Placeholder(1) {
	case "@p1":
		rewrite = mysqlDDLToTSQL
	case ":1":
		rewrite = mysqlDDLToOracle
	}
	q := eng.Querier()
	for _, stmt := range stmts {
		if rewrite != nil {
			stmt = rewrite(stmt)
		}
		if err := q.Exec(ctx, stmt); err != nil {
			return err
		}
	}
	return nil
}

var (
	reIfNotExists = regexp.MustCompile(`CREATE TABLE IF NOT EXISTS (\w+)`)
	reUniqueKey   = regexp.MustCompile(`UNIQUE KEY (\w+) \(`)
	reDatetime    = regexp.MustCompile(`\bDATETIME\b`)
	reDouble      = regexp.MustCompile(`\bDOUBLE\b`)
)

// mysqlDDLToTSQL rewrites the four MySQL DDL idioms the QA fixtures use into
// their T-SQL equivalents:
//   - CREATE TABLE IF NOT EXISTS x → IF OBJECT_ID('x') IS NULL CREATE TABLE x
//     (T-SQL has no IF NOT EXISTS clause);
//   - DATETIME → DATETIME2(6) (the framework timestamp shape);
//   - TINYINT(1) → BIT, DOUBLE → FLOAT;
//   - UNIQUE KEY name (cols) → CONSTRAINT name UNIQUE (cols).
//
// Everything else in the MySQL shapes (BINARY(16), VARCHAR, DEFAULT
// CURRENT_TIMESTAMP, PRIMARY KEY, FOREIGN KEY … ON DELETE CASCADE) is already
// valid T-SQL.
func mysqlDDLToTSQL(ddl string) string {
	ddl = reIfNotExists.ReplaceAllString(ddl, "IF OBJECT_ID('$1') IS NULL CREATE TABLE $1")
	ddl = reUniqueKey.ReplaceAllString(ddl, "CONSTRAINT $1 UNIQUE (")
	ddl = reDatetime.ReplaceAllString(ddl, "DATETIME2(6)")
	ddl = strings.ReplaceAll(ddl, "TINYINT(1)", "BIT")
	ddl = reDouble.ReplaceAllString(ddl, "FLOAT")
	return ddl
}
