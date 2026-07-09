#!/usr/bin/env bash
# Bring up the dedicated DEV bench and run the service in dev mode (auth off) on
# MySQL + NATS JetStream. This bench (devops/docker-compose.dev.yml, project
# `omnicore-dev`, standard ports) is EXCLUSIVELY yours — the QA suites run in the
# separate `omnicore-qa` bench and never touch your data. Ctrl+C stops the Go
# process; the containers stay up.

set -euo pipefail

cd "$(dirname "$0")"

echo "==> Bringing up the dev bench (MySQL + NATS JetStream + Mongo + Debezium Server)"
docker compose -f devops/docker-compose.dev.yml up -d

echo "==> Starting omnicore-example-users (dev · MySQL · NATS)"
mkdir -p devops/elk/logs
# The Debezium Server relay streams as soon as the outbox tables exist — the app
# creates them (migrations) on first boot and creates the JetStream stream, so a
# cold start's first writes land in Mongo a moment after boot.
#
# The `tee` traps INT/TERM: on Ctrl+C the terminal signals the whole foreground
# group at once; a plain `tee` would die immediately, the server's stdout becomes
# a broken pipe, and every graceful-shutdown log line is lost. Trapping keeps
# `tee` alive until the server closes stdout on a clean exit.
env APP_PROFILE=dev OMNICORE_CONFIG_PATH=./microservice.dev-mysql.yaml \
  go run -work -tags 'mysql nats' ./bootstrap 2>&1 \
  | { trap '' INT TERM; tee -a devops/elk/logs/omnicore-example-users.log; }
