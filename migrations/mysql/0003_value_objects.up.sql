-- Value-object fields persisted as their underlying scalar (omnicore VO support).
ALTER TABLE persons                ADD COLUMN ethnicity              VARCHAR(50)  NOT NULL DEFAULT '';
ALTER TABLE users                  ADD COLUMN user_profile          INT          NOT NULL DEFAULT 0;
ALTER TABLE user_configurations    ADD COLUMN notification_email     VARCHAR(255);
ALTER TABLE user_configurations    ADD COLUMN notification_frequency INT;
ALTER TABLE addresses              ADD COLUMN address_type          VARCHAR(30)  NOT NULL DEFAULT '';
ALTER TABLE dependent_health_plans ADD COLUMN health_plan_type      VARCHAR(50);
