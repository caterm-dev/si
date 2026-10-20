#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-Release}"
case "$configuration" in
    Debug|Release) ;;
    *) printf 'Usage: %s [Debug|Release]\n' "$0" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
    printf 'Usage: %s [Debug|Release]\n' "$0" >&2
    exit 2
fi
destination="$HOME/Library/Input Methods/SI.app"
ensure_si_stopped() {
    local status=0
    pgrep -x SI >/dev/null || status=$?
    case "$status" in
        0)
            printf 'SI is running. Stop any Xcode run. If the installed input method is running, select another input source and log out before retrying.\n' >&2
            exit 1
            ;;
        1) ;;
        *)
            printf 'Cannot check whether SI is running. Run this installer in your normal logged-in Terminal session.\n' >&2
            exit 1
            ;;
    esac
}
ensure_si_stopped
"$repo_root/scripts/build.sh" "$configuration"
source_app="$repo_root/.build/xcode/Build/Products/$configuration/SI.app"
mkdir -p "$(dirname "$destination")"
staging="$(mktemp -d "$(dirname "$destination")/.si-install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto "$source_app" "$staging/SI.app"
# Xcode may emit a separate Debug dylib. Sign nested code before the app bundle.
for library in "$staging/SI.app/Contents/MacOS/"*.dylib; do
    if [[ -f "$library" ]]; then
        /usr/bin/codesign --force --sign - "$library"
    fi
done
/usr/bin/codesign --force --sign - "$staging/SI.app"
/usr/bin/codesign --verify --strict "$staging/SI.app"
ensure_si_stopped
if [[ -e "$destination" ]]; then
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")"
    if [[ "$identifier" != 'com.caterm.inputmethod.si' && "$identifier" != 'com.caterm.si' ]]; then
        printf 'Refusing to replace an app with a different bundle identifier: %s\n' "$destination" >&2
        exit 1
    fi
    backup_root="$HOME/Library/Application Support/SI/Backups"
    mkdir -p "$backup_root"
    backup="$backup_root/SI.$(date +%Y%m%d%H%M%S).app"
    if [[ -e "$backup" ]]; then
        printf 'Backup already exists: %s\n' "$backup" >&2
        exit 1
    fi
    mv "$destination" "$backup"
    if ! mv "$staging/SI.app" "$destination"; then
        mv "$backup" "$destination"
        exit 1
    fi
    printf 'Previous installation saved at: %s\n' "$backup"
else
    mv "$staging/SI.app" "$destination"
fi
printf 'Installed: %s\n' "$destination"
xcrun swift "$repo_root/scripts/register-input-source.swift" --register "$destination"
printf 'Add SI in System Settings > Keyboard > Text Input > Edit > + > English.\n'
printf 'If SI is not listed, reopen System Settings; log out and back in only if it is still missing.\n'
