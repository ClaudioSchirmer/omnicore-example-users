-- Lane D provisioning, run once by the gvenzl image on FIRST boot (as SYSDBA).
-- The app user (`omnicore`, created by the image's APP_USER env in FREEPDB1)
-- needs two non-default privileges:
--   * EXECUTE ON SYS.DBMS_LOCK — the framework's rebuild lock AND the
--     migration lock ride DBMS_LOCK session locks (documented operational
--     requirement in the manual's Migrations section);
--   * SELECT_CATALOG_ROLE — the rebuild lock's best-effort holder diagnostic
--     reads v$lock/v$session (degrades to empty without it; granted here so
--     the QA bench exercises the full path).
ALTER SESSION SET CONTAINER = FREEPDB1;
GRANT EXECUTE ON SYS.DBMS_LOCK TO omnicore;
GRANT SELECT_CATALOG_ROLE TO omnicore;
