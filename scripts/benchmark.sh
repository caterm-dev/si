#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="$repo_root/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$repo_root/.build/module-cache"
case "${1:-}" in
    "")
        swift run --configuration release --scratch-path .build/swift SIBenchmark
        ;;
    --resources)
        swift build --configuration release --scratch-path .build/swift --product SIBenchmark >&2
        si_benchmark_bin="$(swift build --configuration release --scratch-path .build/swift --show-bin-path)"
        /usr/bin/time -l "$si_benchmark_bin/SIBenchmark"
        ;;
    --quality)
        swift run --configuration release --scratch-path .build/swift SIBenchmark --quality
        ;;
    --previews)
        swift run --configuration release --scratch-path .build/swift SIBenchmark --previews
        ;;
    --automatic-confirmation)
        swift run --configuration release --scratch-path .build/swift SIBenchmark --automatic-confirmation
        ;;
    *)
        printf 'Usage: %s [--resources|--previews|--quality|--automatic-confirmation]\n' "$0" >&2
        exit 2
        ;;
esac
