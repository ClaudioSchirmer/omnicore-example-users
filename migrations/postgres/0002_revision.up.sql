-- Revision tokens (framework requirement since omnicore v0.36): the
-- commit-order column every entity table and shared base carries.
ALTER TABLE persons   ADD COLUMN revision BIGINT NOT NULL DEFAULT 0;
ALTER TABLE users     ADD COLUMN revision BIGINT NOT NULL DEFAULT 0;
ALTER TABLE employees ADD COLUMN revision BIGINT NOT NULL DEFAULT 0;
