-- ============================================================================
-- MySQL twin of migrations/postgres/0002_init.up.sql. Same logical schema —
-- the four tables that back the FLAT User aggregate (persons SharedBase,
-- addresses base-children, users role, user_configurations sibling) — in MySQL
-- types and idioms:
--   * UUID -> BINARY(16). Ids are generated in Go (UUID v7 for the role/children;
--     deterministic UUIDv5(document) for the person base) and bound as 16 raw
--     bytes by the engine's value codec — so there is NO column default.
--   * TIMESTAMP -> DATETIME, BOOLEAN -> TINYINT(1).
--   * UNIQUE/constraint NAMES match the Postgres migration so the repository's
--     ConstraintBinding maps a 1062 the same way on both backends
--     (users_person_unique -> EntityAlreadyAddedNotification / 409).
-- FKs carry ON DELETE CASCADE only as a safety net — the framework deletes
-- children/siblings and the orphaned base explicitly in Go, in the same TX.
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

-- users: the role. UNIQUE(person_id) enforces 0..1 user per person (re-POST of an
-- archived user revives the same row rather than inserting a second).
CREATE TABLE users (
    id          BINARY(16)   NOT NULL,
    person_id   BINARY(16)   NOT NULL,
    user_name   VARCHAR(100) NOT NULL,
    deleted_at  DATETIME     NULL,
    created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY users_person_unique (person_id),
    CONSTRAINT fk_users_person FOREIGN KEY (person_id) REFERENCES persons (id) ON DELETE CASCADE
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
