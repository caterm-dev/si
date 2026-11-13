#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="$repo_root/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$repo_root/.build/module-cache"
rust_dir="$repo_root/.build/rust-app/test"
export SI_ENGINE_RESOURCE_DIRECTORY="$rust_dir/SIEngine"
export SI_LEGACY_DICTIONARY_DIRECTORY="$repo_root/.build/legacy-dictionaries"
bash scripts/prepare-rust-app.sh "$rust_dir" "$SI_ENGINE_RESOURCE_DIRECTORY"
swift_args=(--configuration release --scratch-path .build/swift -Xlinker "-L$rust_dir")
case "${1:-}" in
    "")
        swift run "${swift_args[@]}" SIBenchmark
        ;;
    --resources)
        swift build "${swift_args[@]}" --product SIBenchmark >&2
        si_benchmark_bin="$(swift build "${swift_args[@]}" --show-bin-path)"
        /usr/bin/time -l "$si_benchmark_bin/SIBenchmark"
        ;;
    --quality)
        swift run "${swift_args[@]}" SIBenchmark --quality
        ;;
    --previews)
        swift run "${swift_args[@]}" SIBenchmark --previews
        ;;
    --automatic-confirmation)
        swift run "${swift_args[@]}" SIBenchmark --automatic-confirmation
        ;;
    *)
        printf 'Usage: %s [--resources|--previews|--quality|--automatic-confirmation]\n' "$0" >&2
        exit 2
        ;;
esac
