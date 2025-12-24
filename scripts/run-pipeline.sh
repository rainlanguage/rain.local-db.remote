#!/bin/bash

# Load nix environment if available
if [ -f /root/.nix-profile/etc/profile.d/nix.sh ]; then
    . /root/.nix-profile/etc/profile.d/nix.sh
elif [ -f /etc/profile.d/nix.sh ]; then
    . /etc/profile.d/nix.sh
fi

REPO_DIR="${1:?Usage: $0 <repo-directory>}"
LOG="$REPO_DIR/pipeline.log"
LOCK=/tmp/pipeline.lock

exec 200>"$LOCK"
if ! flock -n 200; then
    echo "$(date) - skipped, previous run still active" >> "$LOG"
    exit 0
fi

START=$(date +%s)
echo "=== $(date) ===" >> "$LOG"

cd "$REPO_DIR"
nix run .#local-db-pipeline >> "$LOG" 2>&1

ELAPSED=$(($(date +%s) - START))
echo "Finished in $((ELAPSED/60))m $((ELAPSED%60))s" >> "$LOG"
