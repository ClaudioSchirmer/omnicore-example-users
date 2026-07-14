-- ============================================================================
-- SQL Server twin of migrations/mysql/0001_init.up.sql. Same logical schema —
-- the tables that back the User + Employee roles over the shared Person
-- identity — in T-SQL types and idioms:
--   * UUID -> BINARY(16). Ids are generated in Go (UUID v7 for role/children;
--     deterministic UUIDv5(document) for the person base) and bound as 16 raw
--     bytes by the engine's value codec — so there is NO column default.
--     BINARY(16) compares bytewise, keeping the v7 time order in the clustered
--     PK (UNIQUEIDENTIFIER would reorder and fragment it).
--   * TIMESTAMP/DATETIME -> DATETIME2(6), BOOLEAN/TINYINT(1) -> BIT,
--     VARCHAR -> NVARCHAR for human text (labels/names/streets), plain
--     VARCHAR/CHAR for technical ASCII.
--   * Constraint NAMES match the other dialects so the repository's
--     ConstraintBinding maps a 2627/2601 the same way on every backend. For
--     the shared-PK user role the uniqueness IS the PRIMARY KEY (users_pkey).
--   * MySQL's RESTRICT is spelled NO ACTION here — identical veto semantics:
--     the framework's orphan purge runs under a savepoint and treats the FK
--     violation (error 547) as the veto.
-- Child/sibling FKs carry ON DELETE CASCADE only as a safety net — the
-- framework deletes children/siblings explicitly in Go, in the same TX.
-- ============================================================================

-- persons: the shared identity. id = UUIDv5(document); document is the natural key.
CREATE TABLE persons (
    id          BINARY(16)    NOT NULL,
    document    VARCHAR(32)   NOT NULL,
    name        NVARCHAR(255) NOT NULL,
    email       NVARCHAR(255) NOT NULL,
    phone       VARCHAR(20)   NULL,
    deleted_at  DATETIME2(6)  NULL,
    created_at  DATETIME2(6)  NOT NULL CONSTRAINT persons_created_at_default DEFAULT CURRENT_TIMESTAMP,
    updated_at  DATETIME2(6)  NOT NULL CONSTRAINT persons_updated_at_default DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT persons_pkey PRIMARY KEY CLUSTERED (id),
    CONSTRAINT persons_document_key UNIQUE (document)
);

-- addresses: native children of the person (FK person_id), shared by every role.
CREATE TABLE addresses (
    id            BINARY(16)    NOT NULL,
    person_id     BINARY(16)    NOT NULL,
    label         NVARCHAR(50)  NULL,
    street        NVARCHAR(255) NOT NULL,
    number        NVARCHAR(20)  NOT NULL,
    complement    NVARCHAR(100) NULL,
    neighborhood  NVARCHAR(100) NOT NULL,
    city          NVARCHAR(100) NOT NULL,
    state         NVARCHAR(50)  NOT NULL,
    zip_code      VARCHAR(12)   NOT NULL,
    country       CHAR(2)       NOT NULL,
    deleted_at    DATETIME2(6)  NULL,
    created_at    DATETIME2(6)  NOT NULL CONSTRAINT addresses_created_at_default DEFAULT CURRENT_TIMESTAMP,
    updated_at    DATETIME2(6)  NOT NULL CONSTRAINT addresses_updated_at_default DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT addresses_pkey PRIMARY KEY CLUSTERED (id),
    CONSTRAINT fk_addresses_person FOREIGN KEY (person_id) REFERENCES persons (id) ON DELETE CASCADE
);
CREATE INDEX addresses_person_id_idx ON addresses (person_id);

-- users: the role, in the shared-PK model — its own id IS the person's
-- deterministic id (users.id == persons.id): no separate person_id column, and
-- the PRIMARY KEY enforces 0..1 user per person.
CREATE TABLE users (
    id          BINARY(16)    NOT NULL,
    user_name   NVARCHAR(100) NOT NULL,
    deleted_at  DATETIME2(6)  NULL,
    created_at  DATETIME2(6)  NOT NULL CONSTRAINT users_created_at_default DEFAULT CURRENT_TIMESTAMP,
    updated_at  DATETIME2(6)  NOT NULL CONSTRAINT users_updated_at_default DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT users_pkey PRIMARY KEY CLUSTERED (id),
    CONSTRAINT fk_users_person FOREIGN KEY (id) REFERENCES persons (id) ON DELETE NO ACTION
);

-- user_configurations: the sibling slice (notification preferences). Shares the
-- user's primary key 1:1; no lifecycle of its own.
CREATE TABLE user_configurations (
    id                 BINARY(16) NOT NULL,
    email_notification BIT        NULL,
    sms_notification   BIT        NULL,
    CONSTRAINT user_configurations_pkey PRIMARY KEY CLUSTERED (id),
    CONSTRAINT fk_user_configurations_user FOREIGN KEY (id) REFERENCES users (id) ON DELETE CASCADE
);

-- ────────────────────────────────────────────────────────────────────────────
-- Employee: the SECOND role over the same persons SharedBase. Same shared-PK
-- model as users (employees.id == persons.id) and same NO ACTION veto.
CREATE TABLE employees (
    id              BINARY(16)   NOT NULL,
    employee_number VARCHAR(50)  NOT NULL,
    deleted_at      DATETIME2(6) NULL,
    created_at      DATETIME2(6) NOT NULL CONSTRAINT employees_created_at_default DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME2(6) NOT NULL CONSTRAINT employees_updated_at_default DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT employees_pkey PRIMARY KEY CLUSTERED (id),
    CONSTRAINT fk_employees_person FOREIGN KEY (id) REFERENCES persons (id) ON DELETE NO ACTION
);

-- employee_bank_accounts: sibling of employees (1:1, shares the role PK).
CREATE TABLE employee_bank_accounts (
    id      BINARY(16)    NOT NULL,
    bank    NVARCHAR(50)  NULL,
    branch  VARCHAR(20)   NULL,
    account VARCHAR(30)   NULL,
    pix     NVARCHAR(255) NULL,
    CONSTRAINT employee_bank_accounts_pkey PRIMARY KEY CLUSTERED (id),
    CONSTRAINT fk_employee_bank_accounts_employee FOREIGN KEY (id) REFERENCES employees (id) ON DELETE CASCADE
);

-- employee_dependents: ROLE-owned child (FK → the employee, not the person).
CREATE TABLE employee_dependents (
    id           BINARY(16)    NOT NULL,
    employee_id  BINARY(16)    NOT NULL,
    name         NVARCHAR(255) NOT NULL,
    birth_date   DATETIME2(6)  NOT NULL,
    relationship VARCHAR(20)   NOT NULL,
    deleted_at   DATETIME2(6)  NULL,
    created_at   DATETIME2(6)  NOT NULL CONSTRAINT employee_dependents_created_at_default DEFAULT CURRENT_TIMESTAMP,
    updated_at   DATETIME2(6)  NOT NULL CONSTRAINT employee_dependents_updated_at_default DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT employee_dependents_pkey PRIMARY KEY CLUSTERED (id),
    CONSTRAINT fk_employee_dependents_employee FOREIGN KEY (employee_id) REFERENCES employees (id) ON DELETE CASCADE
);
CREATE INDEX employee_dependents_employee_id_idx ON employee_dependents (employee_id);

-- dependent_health_plans: sibling of employee_dependents (1:1 on the CHILD
-- PK) — the child-level (A2b) sibling.
CREATE TABLE dependent_health_plans (
    id         BINARY(16)    NOT NULL,
    provider   NVARCHAR(100) NULL,
    card       VARCHAR(50)   NULL,
    expires_at DATETIME2(6)  NULL,
    CONSTRAINT dependent_health_plans_pkey PRIMARY KEY CLUSTERED (id),
    CONSTRAINT fk_dependent_health_plans_dependent FOREIGN KEY (id) REFERENCES employee_dependents (id) ON DELETE CASCADE
);

-- employee_job_histories: second ROLE-owned child (plain, no sibling).
CREATE TABLE employee_job_histories (
    id            BINARY(16)    NOT NULL,
    employee_id   BINARY(16)    NOT NULL,
    job_title     NVARCHAR(100) NOT NULL,
    department    NVARCHAR(100) NOT NULL,
    hired_at      DATETIME2(6)  NOT NULL,
    terminated_at DATETIME2(6)  NULL,
    deleted_at    DATETIME2(6)  NULL,
    created_at    DATETIME2(6)  NOT NULL CONSTRAINT employee_job_histories_created_at_default DEFAULT CURRENT_TIMESTAMP,
    updated_at    DATETIME2(6)  NOT NULL CONSTRAINT employee_job_histories_updated_at_default DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT employee_job_histories_pkey PRIMARY KEY CLUSTERED (id),
    CONSTRAINT fk_employee_job_histories_employee FOREIGN KEY (employee_id) REFERENCES employees (id) ON DELETE CASCADE
);
CREATE INDEX employee_job_histories_employee_id_idx ON employee_job_histories (employee_id);
