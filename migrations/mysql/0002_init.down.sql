-- Reverse order of 0002_init.up.sql (dependents first). IF EXISTS keeps it idempotent.
DROP TABLE IF EXISTS dependent_health_plans;
DROP TABLE IF EXISTS employee_dependents;
DROP TABLE IF EXISTS employee_job_histories;
DROP TABLE IF EXISTS employee_bank_accounts;
DROP TABLE IF EXISTS employees;
DROP TABLE IF EXISTS user_configurations;
DROP TABLE IF EXISTS addresses;
DROP TABLE IF EXISTS users;
DROP TABLE IF EXISTS persons;
