#!/usr/bin/env bash
set -euo pipefail

# --- Locate project root and .env ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PROJECT_ROOT/.env" ]; then
  echo "📦 Loading environment variables from $PROJECT_ROOT/.env"
  export $(grep -v '^#' "$PROJECT_ROOT/.env" | xargs)
fi

# --- Validate required vars ---
for var in SETTINGS_YAML_URL HYPER_RPC_API_TOKEN RELEASE_BASE_URL; do
  if [ -z "${!var:-}" ]; then
    echo "❌ Missing required environment variable: $var"
    exit 1
  fi
done

CLI_BIN="${CLI_BIN:-$PROJECT_ROOT/rain-orderbook-cli}"
if [ ! -x "$CLI_BIN" ]; then
  echo "❌ CLI binary not found or not executable at $CLI_BIN"
  exit 1
fi

echo "🌐 Fetching settings YAML from $SETTINGS_YAML_URL"
SETTINGS_YAML="$(curl -fsSL "$SETTINGS_YAML_URL")"

echo "🚀 Running local-db sync via $CLI_BIN"
"$CLI_BIN" local-db sync \
  --settings-yaml "$SETTINGS_YAML" \
  --api-token "$HYPER_RPC_API_TOKEN" \
  --release-base-url "$RELEASE_BASE_URL" \
  --debug-status
