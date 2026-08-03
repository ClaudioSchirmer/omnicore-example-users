-- Value-object fields persisted as their underlying scalar (omnicore VO support).
-- Required enum columns carry a NAMED default constraint so the ADD succeeds on a
-- populated bench; the app always writes a validated member.
ALTER TABLE persons                ADD ethnicity              VARCHAR(50)   NOT NULL CONSTRAINT df_persons_ethnicity     DEFAULT '';
ALTER TABLE users                  ADD user_profile           INT           NOT NULL CONSTRAINT df_users_user_profile     DEFAULT 0;
ALTER TABLE user_configurations    ADD notification_email     NVARCHAR(255) NULL;
ALTER TABLE user_configurations    ADD notification_frequency INT           NULL;
ALTER TABLE addresses              ADD address_type           VARCHAR(30)   NOT NULL CONSTRAINT df_addresses_address_type DEFAULT '';
ALTER TABLE dependent_health_plans ADD health_plan_type       VARCHAR(50)   NULL;
