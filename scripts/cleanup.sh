#!/usr/bin/env bash
set -euo pipefail

# --- Locate project root and optional .env ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PROJECT_ROOT/.env" ]; then
  echo "📦 Loading environment variables from $PROJECT_ROOT/.env"
  # shellcheck disable=SC2046
  export $(grep -v '^#' "$PROJECT_ROOT/.env" | xargs)
fi

ARCHIVE_PATH="${ARCHIVE_PATH:-$PROJECT_ROOT/rain-orderbook-cli.tar.gz}"
BINARY_PATH="${BINARY_PATH:-$PROJECT_ROOT/rain-orderbook-cli}"
LOCAL_DB_DIR="${LOCAL_DB_DIR:-$PROJECT_ROOT/local-db}"

remove_path() {
  local target="$1"
  if [ -e "$target" ]; then
    rm -rf "$target"
    echo "🗑️ Removed $target"
  else
    echo "ℹ️ Nothing to remove at $target"
  fi
}

echo "🧽 Removing CLI artifacts..."
remove_path "$ARCHIVE_PATH"

echo "🧽 Removing local-db directory..."
remove_path "$LOCAL_DB_DIR"

echo "✅ Cleanup complete."
