-- Value-object fields persisted as their underlying scalar (omnicore VO support).
ALTER TABLE persons                ADD COLUMN ethnicity              TEXT    NOT NULL DEFAULT '';
ALTER TABLE users                  ADD COLUMN user_profile          INTEGER NOT NULL DEFAULT 0;
ALTER TABLE user_configurations    ADD COLUMN notification_email     TEXT;
ALTER TABLE user_configurations    ADD COLUMN notification_frequency INTEGER;
ALTER TABLE addresses              ADD COLUMN address_type          TEXT    NOT NULL DEFAULT '';
ALTER TABLE dependent_health_plans ADD COLUMN health_plan_type      TEXT;
