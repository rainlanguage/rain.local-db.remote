#!/usr/bin/env bash

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

cd "$repo_root"

echo "Updating git submodules..."
git submodule update --init --recursive
