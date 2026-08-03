ALTER TABLE dependent_health_plans DROP COLUMN health_plan_type;
ALTER TABLE addresses              DROP COLUMN address_type;
ALTER TABLE user_configurations    DROP COLUMN notification_frequency;
ALTER TABLE user_configurations    DROP COLUMN notification_email;
ALTER TABLE users                  DROP COLUMN user_profile;
ALTER TABLE persons                DROP COLUMN ethnicity;
