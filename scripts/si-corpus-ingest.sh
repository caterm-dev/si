#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

corpus_dir="$repo_root/corpus/chinese/prepared/si-corpus"
shopt -s nullglob
sources=("$corpus_dir"/*/text.txt)
if ((${#sources[@]} == 0)); then
    printf 'No corpus text files found under %s\n' "$corpus_dir" >&2
    exit 1
fi

exec cargo run --release --locked --offline -p si-cli -- \
    --config "$repo_root/config/si.conf" corpus ingest \
    "$repo_root/Data/Engine/main.silex" \
    "$repo_root/Data/Engine/words.sigram" \
    "${sources[@]}"
