#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

exec cargo run --release --locked --offline -p si-cli -- lexicon add \
    "${1:-$repo_root/Data/Engine/main.silex}" \
    0 "$repo_root/Data/Chinese" \
    1 "$repo_root/Data/English"
