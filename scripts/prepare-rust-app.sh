#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
library_dir="$1"
resource_dir="$2"
shift 2
if (( $# == 0 )); then set -- "$(uname -m)"; fi
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
cd "$repo_root"
mkdir -p "$library_dir" "$resource_dir"
library_dir="$(cd "$library_dir" && pwd)"
resource_dir="$(cd "$resource_dir" && pwd)"
cargo_dir="$repo_root/.build/rust-app/cargo"
archives=()
for arch in "$@"; do
    case "$arch" in
        arm64) target=aarch64-apple-darwin ;;
        x86_64) target=x86_64-apple-darwin ;;
        *) printf 'Unsupported Rust app architecture: %s\n' "$arch" >&2; exit 2 ;;
    esac
    cargo build --locked --release --target-dir "$cargo_dir" --target "$target" -p si-macos-bridge
    archives+=("$cargo_dir/$target/release/libsi_macos_bridge.a")
done
xcrun lipo -create "${archives[@]}" -output "$library_dir/libsi_macos_bridge.a"

lexicon="${SI_ENGINE_LEXICON:-}"
grams="${SI_ENGINE_GRAMS:-}"
if [[ -n "$grams" && -z "$lexicon" ]]; then
    printf 'SI_ENGINE_GRAMS requires its paired SI_ENGINE_LEXICON.\n' >&2
    exit 2
fi
cargo build --locked --release --target-dir "$cargo_dir" -p si-cli
cli="$cargo_dir/release/si-cli"
if [[ -z "$lexicon" ]]; then
    lexicon="$resource_dir/main.silex"
    signature="$(shasum -a 256 "$cli" Data/Chinese/*.csv Data/English/*.csv | shasum -a 256)"
    if [[ ! -f "$lexicon" || ! -f "$library_dir/lexicon-inputs" ||
          "$(cat "$library_dir/lexicon-inputs")" != "$signature" ]]; then
        work="$(mktemp -d "$resource_dir/.lexicon.XXXXXX")"
        trap 'rm -rf "$work"' EXIT
        "$cli" lexicon build "$work/main.silex" 0 Data/Chinese 1 Data/English
        install -m 644 "$work/main.silex" "$lexicon"
        printf '%s\n' "$signature" > "$library_dir/lexicon-inputs"
    fi
else
    if [[ -n "$grams" ]]; then
        "$cli" check-resources "$lexicon" "$grams"
    else
        "$cli" check-resources "$lexicon"
    fi
    if [[ ! "$lexicon" -ef "$resource_dir/main.silex" ]]; then
        install -m 644 "$lexicon" "$resource_dir/main.silex"
    fi
    # A later dictionary-only build must recompile the maintained sources.
    rm -f "$library_dir/lexicon-inputs"
fi
if [[ -n "$grams" ]]; then
    if [[ ! "$grams" -ef "$resource_dir/main.sigram" ]]; then
        install -m 644 "$grams" "$resource_dir/main.sigram"
    fi
else
    rm -f "$resource_dir/main.sigram"
fi
for language in Chinese English; do
    mkdir -p "$resource_dir/Notices/$language"
    for notice in "mac/SI/Core/Resources/$language/"*.txt "mac/SI/Core/Resources/$language/"*.md; do
        if [[ -f "$notice" ]]; then install -m 644 "$notice" "$resource_dir/Notices/$language/"; fi
    done
done
