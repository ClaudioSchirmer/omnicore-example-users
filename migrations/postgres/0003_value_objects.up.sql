-- Value-object fields persisted as their underlying scalar (omnicore VO support).
-- Enum VOs store the underlying string/int; the raw VO (NotificationEmail) its
-- string. Required enum columns carry a DEFAULT so the ADD succeeds on a
-- populated bench; the app always writes a validated member (the empty/zero
-- sentinel is rejected before persist and reconstructs as Unknown on read).
ALTER TABLE persons                ADD COLUMN ethnicity              VARCHAR(50)  NOT NULL DEFAULT '';
ALTER TABLE users                  ADD COLUMN user_profile          INTEGER      NOT NULL DEFAULT 0;
ALTER TABLE user_configurations    ADD COLUMN notification_email     VARCHAR(255);
ALTER TABLE user_configurations    ADD COLUMN notification_frequency INTEGER;
ALTER TABLE addresses              ADD COLUMN address_type          VARCHAR(30)  NOT NULL DEFAULT '';
ALTER TABLE dependent_health_plans ADD COLUMN health_plan_type      VARCHAR(50);
