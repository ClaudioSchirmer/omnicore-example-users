-- ============================================================================
-- Domain schema (Postgres) — four tables backing the FLAT User aggregate.
--
-- This service exercises the framework's relational-specialization features; the
-- Go entity stays a single flat *User, and infra/schema.go partitions it:
--   persons             — SharedBase (Party-Role identity), deduplicated by document
--   addresses           — base-children of persons (1:N), shared across the person's roles
--   users               — the role/anchor root (shared PK: users.id == persons.id)
--   user_configurations — Sibling of users (1:1, shares the user PK)
--
-- All ids are application-supplied UUIDs: the framework generates v7 for the role
-- and children, and the deterministic UUIDv5(document) for the person base (no
-- read-back). FKs carry ON DELETE CASCADE only as a safety net — the framework
-- deletes children/siblings and the orphaned base explicitly in Go, same TX.
-- ============================================================================

-- persons: the shared identity. id = UUIDv5(document); document is the natural key.
-- Soft-delete lives here too (unified lifecycle): the base is archived/unarchived/
-- deleted in lock-step with its role via the framework's convergeBase.
CREATE TABLE persons (
    id          UUID         PRIMARY KEY,
    document    VARCHAR(32)  NOT NULL,
    name        VARCHAR(255) NOT NULL,
    email       VARCHAR(255) NOT NULL,
    phone       VARCHAR(20),
    deleted_at  TIMESTAMP,
    created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
    CONSTRAINT persons_document_key UNIQUE (document)
);

-- addresses: native children of the person (FK person_id), shared by every role.
-- state / zip_code stay relaxed (VARCHAR) so the example accepts data from any
-- country: US "CA"/"94103-1234", UK ".../SW1A 1AA", Brazil "PE"/"50000-000", etc.
CREATE TABLE addresses (
    id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    person_id     UUID         NOT NULL REFERENCES persons (id) ON DELETE CASCADE,
    label         VARCHAR(50),
    street        VARCHAR(255) NOT NULL,
    number        VARCHAR(20)  NOT NULL,
    complement    VARCHAR(100),
    neighborhood  VARCHAR(100) NOT NULL,
    city          VARCHAR(100) NOT NULL,
    state         VARCHAR(50)  NOT NULL,
    zip_code      VARCHAR(12)  NOT NULL,
    country       CHAR(2)      NOT NULL,
    deleted_at    TIMESTAMP,
    created_at    TIMESTAMP    NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMP    NOT NULL DEFAULT NOW()
);
CREATE INDEX addresses_person_id_idx ON addresses (person_id);

-- users: the role, in the shared-PK model — its own id IS the person's deterministic
-- id (users.id == persons.id), so there is no separate person_id column and the
-- PRIMARY KEY itself enforces 0..1 user per person. A re-POST for an archived user
-- revives the same row rather than inserting a second one; a concurrency race that
-- loses on the PK (`users_pkey`) is mapped by the repository to the same 409 as the
-- happy-path conflict.
CREATE TABLE users (
    id          UUID         PRIMARY KEY REFERENCES persons (id) ON DELETE CASCADE,
    user_name   VARCHAR(100) NOT NULL,
    deleted_at  TIMESTAMP,
    created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
);

-- user_configurations: the sibling slice (notification preferences). Shares the
-- user's primary key 1:1; no lifecycle of its own (the owner controls it). The
-- framework materializes the row only when at least one preference is non-null.
CREATE TABLE user_configurations (
    id                 UUID    PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    email_notification BOOLEAN,
    sms_notification   BOOLEAN
);
