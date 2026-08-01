-- SQLite (3.35+) supports ALTER TABLE DROP COLUMN (no IF EXISTS clause).
ALTER TABLE persons   DROP COLUMN revision;
ALTER TABLE users     DROP COLUMN revision;
ALTER TABLE employees DROP COLUMN revision;
