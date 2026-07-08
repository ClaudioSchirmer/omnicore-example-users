#!/usr/bin/env bash
# Regenerates proto/gen from the .proto contracts in this directory.
#
# Requires protoc plus the two blessed plugins (protoc-gen-go and
# protoc-gen-connect-go, see ../omnicore/CLAUDE.md — protoc-gen-go-grpc is
# deliberately NOT used) on PATH; `go install` puts them in ~/go/bin.
#
# The -I into the framework checkout resolves the shared read-side contract
# (omnicore/v1/query.proto). Its Go code is generated inside the framework
# (web/grpc/pb), never here.
set -euo pipefail
cd "$(dirname "$0")"

export PATH="$PATH:$HOME/go/bin"
MODULE=github.com/ClaudioSchirmer/omnicore-example-users

protoc \
  -I . \
  -I ../../omnicore/web/grpc/proto \
  --go_out=.. --go_opt=module="$MODULE" \
  --connect-go_out=.. --connect-go_opt=module="$MODULE" \
  users/v1/users.proto \
  qafixtures/v1/qa.proto

echo "generated into proto/gen/"
