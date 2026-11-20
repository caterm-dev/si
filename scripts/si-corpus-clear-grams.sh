#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

exec cargo run --release --locked --offline -p si-cli -- corpus clear-grams \
    "$repo_root/.build/si-data/main.silex" \
    "$repo_root/.build/si-data/words.sigram"
