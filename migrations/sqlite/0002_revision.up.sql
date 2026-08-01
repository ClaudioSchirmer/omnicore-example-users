-- Revision tokens (framework requirement since omnicore v0.36): the
-- commit-order column every entity table and shared base carries. BIGINT → INTEGER.
ALTER TABLE persons   ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE users     ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE employees ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
