#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

lexicon="$repo_root/target/si-data/main.silex"
grams="$repo_root/target/si-data/words.sigram"

cargo run --release --locked --offline -p si-cli -- corpus prune \
    --order 2 --min-count 2 "$lexicon" "$grams"
exec cargo run --release --locked --offline -p si-cli -- corpus prune \
    --order 3 --min-count 3 "$lexicon" "$grams"
