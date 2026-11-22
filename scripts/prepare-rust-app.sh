#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures=false
if [[ "${1:-}" == --fixtures ]]; then
    fixtures=true
    shift
fi
library_dir="$1"
resource_dir="$2"
shift 2
lexicon="$repo_root/Data/Engine/main.silex"
grams="$repo_root/Data/Engine/words.sigram"
if [[ "$fixtures" == false ]]; then
    for snapshot in "$lexicon" "$grams"; do
        if [[ ! -f "$snapshot" ]]; then
            printf 'Missing SI app resource: %s\n' "$snapshot" >&2
            exit 2
        fi
    done
fi
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

cargo build --locked --release --target-dir "$cargo_dir" -p si-cli
cli="$cargo_dir/release/si-cli"
if [[ "$fixtures" == true ]]; then
    signature="$(shasum -a 256 "$cli" Data/Chinese/*.csv Data/English/*.csv | shasum -a 256)"
    if [[ ! -f "$resource_dir/main.silex" || ! -f "$library_dir/lexicon-inputs" ||
          "$(cat "$library_dir/lexicon-inputs")" != "$signature" ]]; then
        work="$(mktemp -d "$resource_dir/.lexicon.XXXXXX")"
        trap 'rm -rf "$work"' EXIT
        "$cli" lexicon build "$work/main.silex" 0 Data/Chinese 1 Data/English
        install -m 644 "$work/main.silex" "$resource_dir/main.silex"
        printf '%s\n' "$signature" > "$library_dir/lexicon-inputs"
    fi
    rm -f "$resource_dir/words.sigram"
else
    work="$(mktemp -d "$resource_dir/.snapshots.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    install -m 644 "$lexicon" "$work/main.silex"
    install -m 644 "$grams" "$work/words.sigram"
    "$cli" check-resources "$work/main.silex" "$work/words.sigram"
    mv -f "$work/main.silex" "$resource_dir/main.silex"
    mv -f "$work/words.sigram" "$resource_dir/words.sigram"
    rm -f "$library_dir/lexicon-inputs"
fi
# Incremental builds may reuse a resource directory from an older app build.
rm -rf "$resource_dir/Ranking"
rm -f "$resource_dir/main.sigram"
mkdir -p "$resource_dir/RerankerSmall"
cp -R Data/RerankerSmall/. "$resource_dir/RerankerSmall/"
chmod -R a+rX "$resource_dir/RerankerSmall"
for language in Chinese English; do
    mkdir -p "$resource_dir/Notices/$language"
    for notice in "mac/SI/Core/Resources/$language/"*.txt "mac/SI/Core/Resources/$language/"*.md; do
        if [[ -f "$notice" ]]; then install -m 644 "$notice" "$resource_dir/Notices/$language/"; fi
    done
done
