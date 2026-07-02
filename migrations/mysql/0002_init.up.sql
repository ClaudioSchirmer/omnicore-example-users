-- ============================================================================
-- MySQL twin of migrations/postgres/0002_init.up.sql. Same logical schema —
-- the four tables that back the FLAT User aggregate (persons SharedBase,
-- addresses base-children, users role, user_configurations sibling) — in MySQL
-- types and idioms:
--   * UUID -> BINARY(16). Ids are generated in Go (UUID v7 for the role/children;
--     deterministic UUIDv5(document) for the person base) and bound as 16 raw
--     bytes by the engine's value codec — so there is NO column default.
--   * TIMESTAMP -> DATETIME, BOOLEAN -> TINYINT(1).
--   * Constraint NAMES match the Postgres migration so the repository's
--     ConstraintBinding maps a 1062 the same way on both backends. For the shared-PK
--     user role the uniqueness IS the PRIMARY KEY: MySQL reports a PK collision as
--     key `PRIMARY`, mapped (alongside Postgres' `users_pkey`) to a 409.
-- Child/sibling FKs carry ON DELETE CASCADE only as a safety net — the framework
-- deletes children/siblings explicitly in Go, in the same TX. The role→persons FK
-- is deliberately RESTRICT: the framework's orphan purge runs under a savepoint
-- and treats an FK violation as a veto, so RESTRICT is what gives any other
-- role/table referencing the person the power to block the purge.
-- ============================================================================

-- persons: the shared identity. id = UUIDv5(document); document is the natural key.
CREATE TABLE persons (
    id          BINARY(16)   NOT NULL,
    document    VARCHAR(32)  NOT NULL,
    name        VARCHAR(255) NOT NULL,
    email       VARCHAR(255) NOT NULL,
    phone       VARCHAR(20)  NULL,
    deleted_at  DATETIME     NULL,
    created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY persons_document_key (document)
);

-- addresses: native children of the person (FK person_id), shared by every role.
CREATE TABLE addresses (
    id            BINARY(16)   NOT NULL,
    person_id     BINARY(16)   NOT NULL,
    label         VARCHAR(50)  NULL,
    street        VARCHAR(255) NOT NULL,
    number        VARCHAR(20)  NOT NULL,
    complement    VARCHAR(100) NULL,
    neighborhood  VARCHAR(100) NOT NULL,
    city          VARCHAR(100) NOT NULL,
    state         VARCHAR(50)  NOT NULL,
    zip_code      VARCHAR(12)  NOT NULL,
    country       CHAR(2)      NOT NULL,
    deleted_at    DATETIME     NULL,
    created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY addresses_person_id_idx (person_id),
    CONSTRAINT fk_addresses_person FOREIGN KEY (person_id) REFERENCES persons (id) ON DELETE CASCADE
);

-- users: the role, in the shared-PK model — its own id IS the person's deterministic
-- id (users.id == persons.id), so there is no separate person_id column and the
-- PRIMARY KEY enforces 0..1 user per person (a re-POST of an archived user revives
-- the same row rather than inserting a second).
CREATE TABLE users (
    id          BINARY(16)   NOT NULL,
    user_name   VARCHAR(100) NOT NULL,
    deleted_at  DATETIME     NULL,
    created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    CONSTRAINT fk_users_person FOREIGN KEY (id) REFERENCES persons (id) ON DELETE RESTRICT
);

-- user_configurations: the sibling slice (notification preferences). Shares the
-- user's primary key 1:1; no lifecycle of its own. Materialized only when at
-- least one preference is non-null.
CREATE TABLE user_configurations (
    id                 BINARY(16) NOT NULL,
    email_notification TINYINT(1) NULL,
    sms_notification   TINYINT(1) NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_user_configurations_user FOREIGN KEY (id) REFERENCES users (id) ON DELETE CASCADE
);

-- ────────────────────────────────────────────────────────────────────────────
-- Employee: the SECOND role over the same persons SharedBase. Same shared-PK
-- model as users (employees.id == persons.id) and same RESTRICT rationale —
-- each role's FK is a physical veto against purging a person another role
-- still references.
CREATE TABLE employees (
    id          BINARY(16)   NOT NULL,
    employee_number   VARCHAR(50)  NOT NULL,
    deleted_at  DATETIME     NULL,
    created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    CONSTRAINT fk_employees_person FOREIGN KEY (id) REFERENCES persons (id) ON DELETE RESTRICT
);

-- employee_bank_accounts: sibling of employees (1:1, shares the role PK).
CREATE TABLE employee_bank_accounts (
    id      BINARY(16)   NOT NULL,
    bank   VARCHAR(50)  NULL,
    branch VARCHAR(20)  NULL,
    account   VARCHAR(30)  NULL,
    pix     VARCHAR(255) NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_employee_bank_accounts_employee FOREIGN KEY (id) REFERENCES employees (id) ON DELETE CASCADE
);

-- employee_dependents: ROLE-owned child (FK → the employee, not the person).
CREATE TABLE employee_dependents (
    id             BINARY(16)   NOT NULL,
    employee_id BINARY(16)   NOT NULL,
    name           VARCHAR(255) NOT NULL,
    birth_date     DATETIME     NOT NULL,
    relationship     VARCHAR(20)  NOT NULL,
    deleted_at     DATETIME     NULL,
    created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY employee_dependents_employee_id_idx (employee_id),
    CONSTRAINT fk_employee_dependents_employee FOREIGN KEY (employee_id) REFERENCES employees (id) ON DELETE CASCADE
);

-- dependent_health_plans: sibling of employee_dependents (1:1 on the CHILD
-- PK) — the child-level (A2b) sibling.
CREATE TABLE dependent_health_plans (
    id             BINARY(16)   NOT NULL,
    provider      VARCHAR(100) NULL,
    card    VARCHAR(50)  NULL,
    expires_at DATETIME     NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_dependent_health_plans_dependent FOREIGN KEY (id) REFERENCES employee_dependents (id) ON DELETE CASCADE
);

-- employee_job_histories: second ROLE-owned child (plain, no sibling).
CREATE TABLE employee_job_histories (
    id             BINARY(16)   NOT NULL,
    employee_id BINARY(16)   NOT NULL,
    job_title          VARCHAR(100) NOT NULL,
    department   VARCHAR(100) NOT NULL,
    hired_at       DATETIME     NOT NULL,
    terminated_at   DATETIME     NULL,
    deleted_at     DATETIME     NULL,
    created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY employee_job_histories_employee_id_idx (employee_id),
    CONSTRAINT fk_employee_job_histories_employee FOREIGN KEY (employee_id) REFERENCES employees (id) ON DELETE CASCADE
);
