-- ============================================================================
-- Oracle twin of migrations/mysql/0001_init.up.sql. Same logical schema — the
-- tables that back the User + Employee roles over the shared Person identity —
-- in Oracle types and idioms (floor: Oracle Database 23ai, the framework's
-- oracle engine requirement):
--   * UUID -> RAW(16). Ids are generated in Go (UUID v7 for role/children;
--     deterministic UUIDv5(document) for the person base) and bound as 16 raw
--     bytes by the engine's value codec — so there is NO column default.
--     RAW compares bytewise, keeping the v7 time order in the PK index.
--   * TIMESTAMP/DATETIME -> TIMESTAMP(6) (DEFAULT SYSTIMESTAMP — the server-tz
--     "now"; Oracle requires DEFAULT before NOT NULL), BOOLEAN/TINYINT(1) ->
--     native BOOLEAN (23ai), VARCHAR -> VARCHAR2(n CHAR) for human text
--     (labels/names/streets), plain VARCHAR2/CHAR for technical ASCII.
--   * Identifiers are UNQUOTED except reserved-word collisions, quoted in
--     UPPERCASE ("NUMBER") — both resolve to the same uppercase catalog names
--     the engine's quoted-uppercase identifiers address.
--   * Constraint NAMES match the other dialects so the repository's
--     ConstraintBinding maps an ORA-00001 the same way on every backend. For
--     the shared-PK user role the uniqueness IS the PRIMARY KEY (users_pkey).
--   * MySQL's RESTRICT has no Oracle spelling — OMITTING the ON DELETE clause
--     IS the restrict/no-action default; identical veto semantics: the
--     framework's orphan purge runs under a savepoint and treats the FK
--     violation (ORA-02292) as the veto.
-- Child/sibling FKs carry ON DELETE CASCADE only as a safety net — the
-- framework deletes children/siblings explicitly in Go, in the same TX.
-- ============================================================================

-- persons: the shared identity. id = UUIDv5(document); document is the natural key.
CREATE TABLE persons (
    id          RAW(16)            NOT NULL,
    document    VARCHAR2(32)       NOT NULL,
    name        VARCHAR2(255 CHAR) NOT NULL,
    email       VARCHAR2(255 CHAR) NOT NULL,
    phone       VARCHAR2(20)       NULL,
    deleted_at  TIMESTAMP(6)       NULL,
    created_at  TIMESTAMP(6)       DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at  TIMESTAMP(6)       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT persons_pkey PRIMARY KEY (id),
    CONSTRAINT persons_document_key UNIQUE (document)
);

-- addresses: native children of the person (FK person_id), shared by every role.
CREATE TABLE addresses (
    id            RAW(16)            NOT NULL,
    person_id     RAW(16)            NOT NULL,
    label         VARCHAR2(50 CHAR)  NULL,
    street        VARCHAR2(255 CHAR) NOT NULL,
    -- `number` collides with an Oracle reserved word (ORA-03050): quoted
    -- UPPERCASE it resolves to the SAME catalog name the engine's
    -- quoted-uppercase identifiers address — the documented DDL rule.
    "NUMBER"      VARCHAR2(20 CHAR)  NOT NULL,
    complement    VARCHAR2(100 CHAR) NULL,
    neighborhood  VARCHAR2(100 CHAR) NOT NULL,
    city          VARCHAR2(100 CHAR) NOT NULL,
    state         VARCHAR2(50 CHAR)  NOT NULL,
    zip_code      VARCHAR2(12)       NOT NULL,
    country       CHAR(2)            NOT NULL,
    deleted_at    TIMESTAMP(6)       NULL,
    created_at    TIMESTAMP(6)       DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at    TIMESTAMP(6)       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT addresses_pkey PRIMARY KEY (id),
    CONSTRAINT fk_addresses_person FOREIGN KEY (person_id) REFERENCES persons (id) ON DELETE CASCADE
);
CREATE INDEX addresses_person_id_idx ON addresses (person_id);

-- users: the role, in the shared-PK model — its own id IS the person's
-- deterministic id (users.id == persons.id): no separate person_id column, and
-- the PRIMARY KEY enforces 0..1 user per person.
CREATE TABLE users (
    id          RAW(16)            NOT NULL,
    user_name   VARCHAR2(100 CHAR) NOT NULL,
    deleted_at  TIMESTAMP(6)       NULL,
    created_at  TIMESTAMP(6)       DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at  TIMESTAMP(6)       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT users_pkey PRIMARY KEY (id),
    CONSTRAINT fk_users_person FOREIGN KEY (id) REFERENCES persons (id)
);

-- user_configurations: the sibling slice (notification preferences). Shares the
-- user's primary key 1:1; no lifecycle of its own.
CREATE TABLE user_configurations (
    id                 RAW(16) NOT NULL,
    email_notification BOOLEAN NULL,
    sms_notification   BOOLEAN NULL,
    CONSTRAINT user_configurations_pkey PRIMARY KEY (id),
    CONSTRAINT fk_user_configurations_user FOREIGN KEY (id) REFERENCES users (id) ON DELETE CASCADE
);

-- ────────────────────────────────────────────────────────────────────────────
-- Employee: the SECOND role over the same persons SharedBase. Same shared-PK
-- model as users (employees.id == persons.id) and same no-action veto.
CREATE TABLE employees (
    id              RAW(16)      NOT NULL,
    employee_number VARCHAR2(50) NOT NULL,
    deleted_at      TIMESTAMP(6) NULL,
    created_at      TIMESTAMP(6) DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at      TIMESTAMP(6) DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT employees_pkey PRIMARY KEY (id),
    CONSTRAINT fk_employees_person FOREIGN KEY (id) REFERENCES persons (id)
);

-- employee_bank_accounts: sibling of employees (1:1, shares the role PK).
CREATE TABLE employee_bank_accounts (
    id      RAW(16)            NOT NULL,
    bank    VARCHAR2(50 CHAR)  NULL,
    branch  VARCHAR2(20)       NULL,
    account VARCHAR2(30)       NULL,
    pix     VARCHAR2(255 CHAR) NULL,
    CONSTRAINT employee_bank_accounts_pkey PRIMARY KEY (id),
    CONSTRAINT fk_employee_bank_accounts_employee FOREIGN KEY (id) REFERENCES employees (id) ON DELETE CASCADE
);

-- employee_dependents: ROLE-owned child (FK → the employee, not the person).
CREATE TABLE employee_dependents (
    id           RAW(16)            NOT NULL,
    employee_id  RAW(16)            NOT NULL,
    name         VARCHAR2(255 CHAR) NOT NULL,
    birth_date   TIMESTAMP(6)       NOT NULL,
    relationship VARCHAR2(20)       NOT NULL,
    deleted_at   TIMESTAMP(6)       NULL,
    created_at   TIMESTAMP(6)       DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at   TIMESTAMP(6)       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT employee_dependents_pkey PRIMARY KEY (id),
    CONSTRAINT fk_employee_dependents_employee FOREIGN KEY (employee_id) REFERENCES employees (id) ON DELETE CASCADE
);
CREATE INDEX employee_dependents_employee_id_idx ON employee_dependents (employee_id);

-- dependent_health_plans: sibling of employee_dependents (1:1 on the CHILD
-- PK) — the child-level (A2b) sibling.
CREATE TABLE dependent_health_plans (
    id         RAW(16)            NOT NULL,
    provider   VARCHAR2(100 CHAR) NULL,
    card       VARCHAR2(50)       NULL,
    expires_at TIMESTAMP(6)       NULL,
    CONSTRAINT dependent_health_plans_pkey PRIMARY KEY (id),
    CONSTRAINT fk_dependent_health_plans_dependent FOREIGN KEY (id) REFERENCES employee_dependents (id) ON DELETE CASCADE
);

-- employee_job_histories: second ROLE-owned child (plain, no sibling).
CREATE TABLE employee_job_histories (
    id            RAW(16)            NOT NULL,
    employee_id   RAW(16)            NOT NULL,
    job_title     VARCHAR2(100 CHAR) NOT NULL,
    department    VARCHAR2(100 CHAR) NOT NULL,
    hired_at      TIMESTAMP(6)       NOT NULL,
    terminated_at TIMESTAMP(6)       NULL,
    deleted_at    TIMESTAMP(6)       NULL,
    created_at    TIMESTAMP(6)       DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at    TIMESTAMP(6)       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT employee_job_histories_pkey PRIMARY KEY (id),
    CONSTRAINT fk_employee_job_histories_employee FOREIGN KEY (employee_id) REFERENCES employees (id) ON DELETE CASCADE
);
CREATE INDEX employee_job_histories_employee_id_idx ON employee_job_histories (employee_id);
