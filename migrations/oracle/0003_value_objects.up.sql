-- Value-object fields persisted as their underlying scalar (omnicore VO support).
-- Oracle treats '' as NULL, so a required enum-string column defaults to a single
-- space (a non-member that reconstructs as Unknown on read) — only ever seen by a
-- pre-existing row; the app always writes a validated member.
ALTER TABLE persons                ADD (ethnicity              VARCHAR2(50 CHAR)  DEFAULT ' ' NOT NULL);
ALTER TABLE users                  ADD (user_profile          NUMBER(10)         DEFAULT 0 NOT NULL);
ALTER TABLE user_configurations    ADD (notification_email     VARCHAR2(255 CHAR));
ALTER TABLE user_configurations    ADD (notification_frequency NUMBER(10));
ALTER TABLE addresses              ADD (address_type          VARCHAR2(30 CHAR)  DEFAULT ' ' NOT NULL);
ALTER TABLE dependent_health_plans ADD (health_plan_type      VARCHAR2(50 CHAR));
