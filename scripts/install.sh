#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="$HOME/Library/Input Methods/SI.app"
if pgrep -x SI >/dev/null; then
    printf 'SI is running. Select another input source, log out, then retry installation.\n' >&2
    exit 1
fi
"$repo_root/scripts/build.sh" Debug
source_app="$repo_root/.build/xcode/Build/Products/Debug/SI.app"
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
if [[ -e "$destination" ]]; then
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")"
    if [[ "$identifier" != 'com.caterm.si' ]]; then
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
printf 'Log out and back in, then add SI in System Settings > Keyboard > Text Input.\n'
