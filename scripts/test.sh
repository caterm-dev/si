#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
# Keep compiler caches inside the checkout for predictable local and CI builds.
export CLANG_MODULE_CACHE_PATH="$repo_root/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$repo_root/.build/module-cache"
rust_dir="$repo_root/.build/rust-app/test"
export SI_ENGINE_RESOURCE_DIRECTORY="$rust_dir/SIEngine"
bash scripts/prepare-rust-app.sh --fixtures "$rust_dir" "$SI_ENGINE_RESOURCE_DIRECTORY"
swift test --scratch-path .build/swift -Xlinker "-L$rust_dir" "$@"
