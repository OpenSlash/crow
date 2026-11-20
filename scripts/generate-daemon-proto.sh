#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON_DIR="$ROOT_DIR/apps/daemon"

export PATH="$(go env GOPATH)/bin:$PATH"

mkdir -p "$DAEMON_DIR/gen"

protoc \
  -I "$ROOT_DIR/proto" \
  --go_out="$DAEMON_DIR" \
  --go_opt=module=github.com/crow/crow/apps/daemon \
  --connect-go_out="$DAEMON_DIR" \
  --connect-go_opt=module=github.com/crow/crow/apps/daemon \
  "$ROOT_DIR/proto/crow/v1/crow.proto"

