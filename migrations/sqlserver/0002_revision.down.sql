ALTER TABLE persons   DROP CONSTRAINT df_persons_revision;
ALTER TABLE persons   DROP COLUMN revision;
ALTER TABLE users     DROP CONSTRAINT df_users_revision;
ALTER TABLE users     DROP COLUMN revision;
ALTER TABLE employees DROP CONSTRAINT df_employees_revision;
ALTER TABLE employees DROP COLUMN revision;
