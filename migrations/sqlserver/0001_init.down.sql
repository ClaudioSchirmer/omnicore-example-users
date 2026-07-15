-- Reverse of 0001_init.up.sql (SQL Server). Children/siblings first, then
-- roles, then the shared base.
DROP TABLE IF EXISTS dependent_health_plans;
DROP TABLE IF EXISTS employee_job_histories;
DROP TABLE IF EXISTS employee_dependents;
DROP TABLE IF EXISTS employee_bank_accounts;
DROP TABLE IF EXISTS employees;
DROP TABLE IF EXISTS user_configurations;
DROP TABLE IF EXISTS users;
DROP TABLE IF EXISTS addresses;
DROP TABLE IF EXISTS persons;
