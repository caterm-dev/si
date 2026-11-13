#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
# Keep compiler caches inside the checkout for predictable local and CI builds.
export CLANG_MODULE_CACHE_PATH="$repo_root/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$repo_root/.build/module-cache"
rust_dir="$repo_root/.build/rust-app/test"
export SI_ENGINE_RESOURCE_DIRECTORY="$rust_dir/SIEngine"
export SI_LEGACY_DICTIONARY_DIRECTORY="$repo_root/.build/legacy-dictionaries"
bash scripts/prepare-rust-app.sh "$rust_dir" "$SI_ENGINE_RESOURCE_DIRECTORY"
if [[ ! -f "$SI_LEGACY_DICTIONARY_DIRECTORY/Chinese/si-pinyin.sqlite" ||
      ! -f "$SI_LEGACY_DICTIONARY_DIRECTORY/English/si-english.sqlite" ]]; then
    python3 scripts/csv_dictionary.py build
fi
swift test --scratch-path .build/swift -Xlinker "-L$rust_dir" "$@"
