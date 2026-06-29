-- ============================================================================
-- users: aggregate root.
-- ============================================================================
CREATE TABLE users (
    id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    name        VARCHAR(255) NOT NULL,
    email       VARCHAR(255) NOT NULL,
    phone       VARCHAR(20),
    deleted_at  TIMESTAMP,
    created_at  TIMESTAMP    NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMP    NOT NULL DEFAULT NOW()
);

-- Soft-delete-aware uniqueness: an archived user's email can be reused.
CREATE UNIQUE INDEX users_email_active_idx ON users (email) WHERE deleted_at IS NULL;

-- ============================================================================
-- addresses: AggregateValueObject of User. Lifecycle managed by the User aggregate.
-- ON DELETE CASCADE only fires on hard deletes; soft-delete leaves addresses
-- intact (User aggregate is responsible for archiving children when archiving root).
--
-- state / zip_code are intentionally relaxed (VARCHAR, no fixed length) so the
-- example accepts data from any country: US "CA"/"94103-1234", UK ".../"SW1A 1AA",
-- Brazil "PE"/"50000-000", Germany "Bayern"/"80331", etc. Country is required —
-- no default — clients must declare it.
-- ============================================================================
CREATE TABLE addresses (
    id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
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

CREATE INDEX addresses_user_id_idx ON addresses (user_id);
