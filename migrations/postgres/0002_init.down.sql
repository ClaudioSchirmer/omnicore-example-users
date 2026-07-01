-- Reverse order of 0002_init.up.sql (dependents first). IF EXISTS keeps it idempotent.
DROP TABLE IF EXISTS user_configurations;
DROP TABLE IF EXISTS addresses;
DROP TABLE IF EXISTS users;
DROP TABLE IF EXISTS persons;
