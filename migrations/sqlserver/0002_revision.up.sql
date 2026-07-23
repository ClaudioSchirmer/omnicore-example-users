-- Revision tokens (framework requirement since omnicore v0.36).
ALTER TABLE persons   ADD revision BIGINT NOT NULL CONSTRAINT df_persons_revision   DEFAULT 0;
ALTER TABLE users     ADD revision BIGINT NOT NULL CONSTRAINT df_users_revision     DEFAULT 0;
ALTER TABLE employees ADD revision BIGINT NOT NULL CONSTRAINT df_employees_revision DEFAULT 0;
