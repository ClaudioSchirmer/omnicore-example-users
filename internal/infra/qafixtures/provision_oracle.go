//go:build qa

package qafixtures

import "regexp"

var (
	// `NOT NULL DEFAULT CURRENT_TIMESTAMP` must ALSO swap the clause order:
	// Oracle requires DEFAULT before the column constraints.
	reNotNullDefaultNow = regexp.MustCompile(`NOT NULL DEFAULT CURRENT_TIMESTAMP\b`)
	// The revision token column ships as `NOT NULL DEFAULT 0` in the shared
	// DDL — same clause-order swap (Oracle wants DEFAULT first).
	reNotNullDefaultZero = regexp.MustCompile(`NOT NULL DEFAULT 0\b`)
	reDefaultNow        = regexp.MustCompile(`DEFAULT CURRENT_TIMESTAMP\b`)
	reVarchar           = regexp.MustCompile(`\bVARCHAR\(`)
	reBinary16          = regexp.MustCompile(`\bBINARY\(16\)`)
	reBigint            = regexp.MustCompile(`\bBIGINT\b`)
	reUniqueKeyOra      = regexp.MustCompile(`UNIQUE KEY (\w+) \(`)
	reDatetimeOra       = regexp.MustCompile(`\bDATETIME\b`)
	reDoubleOra         = regexp.MustCompile(`\bDOUBLE\b`)
)

// mysqlDDLToOracle rewrites the MySQL DDL idioms the QA fixtures use into
// their Oracle equivalents (floor: Oracle Database 23ai — the framework's
// oracle engine requirement, which is also why CREATE TABLE IF NOT EXISTS
// passes through untouched: IF NOT EXISTS is native on 23ai):
//   - BINARY(16) → RAW(16) (the dialect's id form);
//   - DATETIME → TIMESTAMP(6); DEFAULT CURRENT_TIMESTAMP → DEFAULT
//     SYSTIMESTAMP, with the `NOT NULL DEFAULT …` order swapped (Oracle wants
//     DEFAULT before the constraints);
//   - VARCHAR(n) → VARCHAR2(n), TINYINT(1) → BOOLEAN (native), DOUBLE →
//     BINARY_DOUBLE, BIGINT → NUMBER(19);
//   - UNIQUE KEY name (cols) → CONSTRAINT name UNIQUE (cols).
//
// Everything else in the MySQL shapes (INT, JSON — native on 23ai —,
// PRIMARY KEY, FOREIGN KEY … ON DELETE CASCADE) is already valid Oracle.
func mysqlDDLToOracle(ddl string) string {
	ddl = reNotNullDefaultNow.ReplaceAllString(ddl, "DEFAULT SYSTIMESTAMP NOT NULL")
	ddl = reNotNullDefaultZero.ReplaceAllString(ddl, "DEFAULT 0 NOT NULL")
	ddl = reDefaultNow.ReplaceAllString(ddl, "DEFAULT SYSTIMESTAMP")
	ddl = reDatetimeOra.ReplaceAllString(ddl, "TIMESTAMP(6)")
	ddl = reBinary16.ReplaceAllString(ddl, "RAW(16)")
	ddl = reVarchar.ReplaceAllString(ddl, "VARCHAR2(")
	ddl = reUniqueKeyOra.ReplaceAllString(ddl, "CONSTRAINT $1 UNIQUE (")
	ddl = reDoubleOra.ReplaceAllString(ddl, "BINARY_DOUBLE")
	ddl = reBigint.ReplaceAllString(ddl, "NUMBER(19)")
	ddl = regexp.MustCompile(`\bTINYINT\(1\)`).ReplaceAllString(ddl, "BOOLEAN")
	return ddl
}
