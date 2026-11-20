#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/tmp/bin"
BIN="$BIN_DIR/crow-cloud"

cd "$ROOT"
export PATH="/usr/local/go/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
export PORT="${PORT:-18089}"
mkdir -p "$BIN_DIR"
go build -o "$BIN" ./server/cmd/crow-cloud
exec "$BIN"
