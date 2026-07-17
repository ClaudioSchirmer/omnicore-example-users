#!/bin/bash
# Lane D CDC provisioning (Debezium OracleConnector via LogMiner), run once by
# the gvenzl image on FIRST boot (as the oracle OS user). A shell script — not
# plain .sql — because the FRA directory must EXIST before the spfile points
# at it (ORA-01261 otherwise). Three pieces:
#   1. ARCHIVELOG mode + minimal supplemental logging — LogMiner reads the
#      archived+online redo. The FRA is bounded (10G) so archived redo cannot
#      grow unbounded on a long-lived bench.
#   2. A dedicated LOGMINER_TBS tablespace in the CDB root AND FREEPDB1 — the
#      canonical Debezium recipe.
#   3. The c##dbzuser COMMON user (multitenant requires the c## prefix) with
#      the connector's documented grant set, CONTAINER=ALL.
# Per-TABLE supplemental logging (outbox + integration_events) is NOT here:
# those tables are created by the app's migrations later —
# register-connector.sh adds it idempotently before registering.
set -e
mkdir -p /opt/oracle/oradata/recovery_area

sqlplus -S / as sysdba <<'EOF'
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SYSTEM SET db_recovery_file_dest_size = 10G;
ALTER SYSTEM SET db_recovery_file_dest = '/opt/oracle/oradata/recovery_area';
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
ALTER PLUGGABLE DATABASE ALL OPEN;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;

CREATE TABLESPACE logminer_tbs DATAFILE '/opt/oracle/oradata/FREE/logminer_tbs.dbf'
  SIZE 25M REUSE AUTOEXTEND ON MAXSIZE UNLIMITED;
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE TABLESPACE logminer_tbs DATAFILE '/opt/oracle/oradata/FREE/FREEPDB1/logminer_tbs.dbf'
  SIZE 25M REUSE AUTOEXTEND ON MAXSIZE UNLIMITED;
ALTER SESSION SET CONTAINER = CDB$ROOT;

CREATE USER c##dbzuser IDENTIFIED BY "OmnicoreQA!2026"
  DEFAULT TABLESPACE logminer_tbs QUOTA UNLIMITED ON logminer_tbs
  CONTAINER=ALL;

GRANT CREATE SESSION TO c##dbzuser CONTAINER=ALL;
GRANT SET CONTAINER TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$DATABASE TO c##dbzuser CONTAINER=ALL;
GRANT FLASHBACK ANY TABLE TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ANY TABLE TO c##dbzuser CONTAINER=ALL;
GRANT SELECT_CATALOG_ROLE TO c##dbzuser CONTAINER=ALL;
GRANT EXECUTE_CATALOG_ROLE TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ANY TRANSACTION TO c##dbzuser CONTAINER=ALL;
GRANT LOGMINING TO c##dbzuser CONTAINER=ALL;
GRANT CREATE TABLE TO c##dbzuser CONTAINER=ALL;
GRANT LOCK ANY TABLE TO c##dbzuser CONTAINER=ALL;
GRANT CREATE SEQUENCE TO c##dbzuser CONTAINER=ALL;
GRANT EXECUTE ON DBMS_LOGMNR TO c##dbzuser CONTAINER=ALL;
GRANT EXECUTE ON DBMS_LOGMNR_D TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOG TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOG_HISTORY TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOGMNR_LOGS TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOGMNR_CONTENTS TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOGMNR_PARAMETERS TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOGFILE TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$ARCHIVED_LOG TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$ARCHIVE_DEST_STATUS TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$TRANSACTION TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$MYSTAT TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$STATNAME TO c##dbzuser CONTAINER=ALL;

-- Heartbeat table for the connectors' heartbeat.action.query: a periodic
-- UPDATE here generates redo so the SCN keeps advancing on an otherwise idle
-- database — without it, LogMiner holds the LAST event of a burst until new
-- redo appears (an archive followed by reads = minutes of tail latency).
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE TABLE c##dbzuser.debezium_heartbeat (id NUMBER(1) PRIMARY KEY, ts TIMESTAMP(6));
INSERT INTO c##dbzuser.debezium_heartbeat VALUES (1, SYSTIMESTAMP);
COMMIT;
EXIT
EOF
echo "02_cdc.sh: ARCHIVELOG + supplemental logging + c##dbzuser provisioned."
