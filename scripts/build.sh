#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-Debug}"
case "$configuration" in
    Debug|Release) ;;
    *) printf 'Usage: %s [Debug|Release]\n' "$0" >&2; exit 2 ;;
esac
cd "$repo_root"
xcodebuild -project mac/SI.xcodeproj -scheme SI \
    -configuration "$configuration" -destination 'generic/platform=macOS' \
    -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
printf '\nBuilt: %s/.build/xcode/Build/Products/%s/SI.app\n' "$repo_root" "$configuration"
