#!/usr/bin/env bash
# Bring up the local bench and run the service in dev mode (auth off).
# Logs stream to stdout AND are mirrored to devops/elk/logs/ so Filebeat ships
# them to Elasticsearch / Kibana (:5601). Run devops/elk/setup-kibana.sh once to
# create the Kibana views. Ctrl+C stops the Go process; containers stay up.

set -euo pipefail

cd "$(dirname "$0")"

echo "==> Bringing up local bench (relational backend + Mongo + Kafka + Debezium)"
docker compose -f devops/docker-compose.yml up -d

echo "==> Waiting for Debezium Connect to be ready"
until curl -sf http://localhost:8083/ >/dev/null 2>&1; do
  sleep 1
done

echo "==> Registering Debezium outbox connector (idempotent)"
./devops/debezium/register-connector.sh || true

echo "==> Starting omnicore-example-users (APP_PROFILE=dev)"
mkdir -p devops/elk/logs
# The `tee` must ignore INT/TERM. On Ctrl+C the terminal signals the whole
# foreground process group at once; a plain `tee` dies immediately, the
# server's stdout becomes a broken pipe, and every graceful-shutdown log line
# is lost (Go even raises SIGPIPE on the first shutdown write). Trapping the
# signals keeps `tee` alive until the server closes stdout on a clean exit, so
# the drain output is captured both on screen and in the mirrored log.
env APP_PROFILE=dev go run -work -tags postgres ./bootstrap 2>&1 \
  | { trap '' INT TERM; tee -a devops/elk/logs/omnicore-example-users.log; }
