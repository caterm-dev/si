#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

exec cargo run --release --locked --offline -p si-cli -- \
    --config "$repo_root/config/si.conf" lexicon learn \
    "$repo_root/.build/si-data/main.silex" \
    "$repo_root/.build/si-data/words.sigram"
