-- Revision tokens (framework requirement since omnicore v0.36).
ALTER TABLE persons   ADD (revision NUMBER(19) DEFAULT 0 NOT NULL);
ALTER TABLE users     ADD (revision NUMBER(19) DEFAULT 0 NOT NULL);
ALTER TABLE employees ADD (revision NUMBER(19) DEFAULT 0 NOT NULL);
