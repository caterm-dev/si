#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

lexicon="$repo_root/.build/si-data/main.silex"
grams="$repo_root/.build/si-data/words.sigram"

cargo run --release --locked --offline -p si-cli -- corpus prune \
    --order 2 --min-count 2 "$lexicon" "$grams"
exec cargo run --release --locked --offline -p si-cli -- corpus prune \
    --order 3 --min-count 5 "$lexicon" "$grams"
