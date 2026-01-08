#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

UPLOAD_BACKEND="${UPLOAD_BACKEND:-spaces}"

echo "⬇️  Downloading CLI binary"
./scripts/download-binary.sh

echo "🔁 Syncing local DB"
./scripts/sync.sh

case "$UPLOAD_BACKEND" in
  spaces)
    echo "☁️  Uploading artifacts to DigitalOcean Spaces"
    ./scripts/do-spaces-upload.sh
    ;;
  r2)
    echo "☁️  Uploading artifacts to Cloudflare R2"
    ./scripts/r2-upload.sh
    ;;
  *)
    echo "❌ Unknown UPLOAD_BACKEND value: $UPLOAD_BACKEND"
    exit 1
    ;;
esac

echo "🧹 Cleaning up artifacts"
./scripts/cleanup.sh

echo "✨ Workflow finished"
