-- ============================================================================
-- MySQL twin of migrations/postgres/0002_init.up.sql. Same logical schema, MySQL
-- types and idioms:
--   * UUID  -> BINARY(16). Ids are generated in Go (UUID v7, time-ordered for
--     InnoDB locality) and bound as 16 raw bytes by the engine's value codec —
--     so there is NO column default (no gen_random_uuid()).
--   * TIMESTAMP -> DATETIME.
--   * The Postgres partial unique index `... WHERE deleted_at IS NULL` has no
--     MySQL equivalent, so soft-delete-aware uniqueness is emulated with a
--     generated column: `email_active` is the email while the row is active and
--     NULL once archived. MySQL allows duplicate NULLs in a UNIQUE index, so an
--     archived user's email becomes reusable — exactly the Postgres semantic.
--     The index keeps the SAME NAME (`users_email_active_idx`) the Postgres
--     migration uses so the repository's single ConstraintBinding maps a 1062 to
--     EmailAlreadyExistsNotification (409) on both backends.
-- ============================================================================
CREATE TABLE users (
    id            BINARY(16)   NOT NULL,
    name          VARCHAR(255) NOT NULL,
    email         VARCHAR(255) NOT NULL,
    phone         VARCHAR(20)  NULL,
    deleted_at    DATETIME     NULL,
    created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    email_active  VARCHAR(255) GENERATED ALWAYS AS (CASE WHEN deleted_at IS NULL THEN email END) VIRTUAL,
    PRIMARY KEY (id),
    UNIQUE KEY users_email_active_idx (email_active)
);

-- ============================================================================
-- addresses: AggregateValueObject of User. ON DELETE CASCADE fires only on hard
-- deletes; soft-delete leaves addresses intact (the User aggregate archives its
-- children when archiving the root). state / zip_code stay relaxed (VARCHAR) so
-- the example accepts data from any country.
-- ============================================================================
CREATE TABLE addresses (
    id            BINARY(16)   NOT NULL,
    user_id       BINARY(16)   NOT NULL,
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
    KEY addresses_user_id_idx (user_id),
    CONSTRAINT fk_addresses_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);
