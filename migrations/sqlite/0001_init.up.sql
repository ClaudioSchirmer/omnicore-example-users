-- ============================================================================
-- Domain schema (SQLite) — the four tables backing the FLAT User aggregate plus
-- the Employee role graph, translated from the Postgres schema for the SQLite
-- engine. Affinities: UUID/VARCHAR/CHAR → TEXT, TIMESTAMP → TEXT, BOOLEAN →
-- INTEGER, BIGINT → INTEGER. DEFAULT NOW() → DEFAULT (strftime …%f). SQLite's
-- default collation is BINARY, so the byte-exact comparison Postgres gets from
-- COLLATE "C" is the default here. Ids are Go-minted (UUID v7 / deterministic
-- UUIDv5), so no gen_random_uuid() default is needed. FKs are enforced because
-- the engine forces PRAGMA foreign_keys(ON) — RESTRICT gives the shared-base
-- orphan-purge veto its teeth, exactly as on the other engines.
-- ============================================================================

CREATE TABLE persons (
    id          TEXT         PRIMARY KEY,
    document    TEXT         NOT NULL,
    name        TEXT         NOT NULL,
    email       TEXT         NOT NULL,
    phone       TEXT,
    deleted_at  TEXT,
    created_at  TEXT         NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    updated_at  TEXT         NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    CONSTRAINT persons_document_key UNIQUE (document)
);

CREATE TABLE addresses (
    id            TEXT         PRIMARY KEY,
    person_id     TEXT         NOT NULL REFERENCES persons (id) ON DELETE CASCADE,
    label         TEXT,
    street        TEXT         NOT NULL,
    number        TEXT         NOT NULL,
    complement    TEXT,
    neighborhood  TEXT         NOT NULL,
    city          TEXT         NOT NULL,
    state         TEXT         NOT NULL,
    zip_code      TEXT         NOT NULL,
    country       TEXT         NOT NULL,
    deleted_at    TEXT,
    created_at    TEXT         NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    updated_at    TEXT         NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
);
CREATE INDEX addresses_person_id_idx ON addresses (person_id);

CREATE TABLE users (
    id          TEXT         PRIMARY KEY REFERENCES persons (id) ON DELETE RESTRICT,
    user_name   TEXT         NOT NULL,
    deleted_at  TEXT,
    created_at  TEXT         NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    updated_at  TEXT         NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
);

CREATE TABLE user_configurations (
    id                 TEXT    PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    email_notification INTEGER,
    sms_notification   INTEGER
);

CREATE TABLE employees (
    id                TEXT         PRIMARY KEY REFERENCES persons (id) ON DELETE RESTRICT,
    employee_number   TEXT         NOT NULL,
    deleted_at        TEXT,
    created_at        TEXT         NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    updated_at        TEXT         NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
);

CREATE TABLE employee_bank_accounts (
    id      TEXT PRIMARY KEY REFERENCES employees (id) ON DELETE CASCADE,
    bank    TEXT,
    branch  TEXT,
    account TEXT,
    pix     TEXT
);

CREATE TABLE employee_dependents (
    id           TEXT         PRIMARY KEY,
    employee_id  TEXT         NOT NULL REFERENCES employees (id) ON DELETE CASCADE,
    name         TEXT         NOT NULL,
    birth_date   TEXT         NOT NULL,
    relationship TEXT         NOT NULL,
    deleted_at   TEXT,
    created_at   TEXT         NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    updated_at   TEXT         NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
);
CREATE INDEX employee_dependents_employee_id_idx ON employee_dependents (employee_id);

CREATE TABLE dependent_health_plans (
    id         TEXT PRIMARY KEY REFERENCES employee_dependents (id) ON DELETE CASCADE,
    provider   TEXT,
    card       TEXT,
    expires_at TEXT
);

CREATE TABLE employee_job_histories (
    id            TEXT         PRIMARY KEY,
    employee_id   TEXT         NOT NULL REFERENCES employees (id) ON DELETE CASCADE,
    job_title     TEXT         NOT NULL,
    department    TEXT         NOT NULL,
    hired_at      TEXT         NOT NULL,
    terminated_at TEXT,
    deleted_at    TEXT,
    created_at    TEXT         NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now')),
    updated_at    TEXT         NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f','now'))
);
CREATE INDEX employee_job_histories_employee_id_idx ON employee_job_histories (employee_id);
