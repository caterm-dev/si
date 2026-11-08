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
# Use the same kind of stable app identity as release packaging. Never fall back
# to ad hoc signing: its code-hash identity loses privacy grants after rebuilds.
requested_identity="${SI_SIGN_IDENTITY:-}"
if ! identities="$(security find-identity -v -p codesigning)"; then
    printf 'Cannot inspect Keychain signing identities. Installation stopped.\n' >&2
    exit 1
fi
identity_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"(Developer ID Application: [^"]+ \([A-Z0-9]{10}\))"'
identity_hashes=()
identity_names=()
while IFS= read -r line; do
    if [[ "$line" =~ $identity_pattern ]]; then
        hash="${BASH_REMATCH[1]}"
        name="${BASH_REMATCH[2]}"
        if [[ -z "$requested_identity" || "$requested_identity" == "$name" || "$requested_identity" == "$hash" ]]; then
            identity_hashes+=("$hash")
            identity_names+=("$name")
        fi
    fi
done <<< "$identities"
if [[ ${#identity_hashes[@]} -eq 0 ]]; then
    printf 'No matching valid Developer ID Application identity. Install its certificate and private key, or check SI_SIGN_IDENTITY.\n' >&2
    exit 1
fi
if [[ ${#identity_hashes[@]} -ne 1 ]]; then
    printf 'Multiple valid Developer ID Application identities. Set SI_SIGN_IDENTITY to a certificate name or SHA-1 fingerprint:\n' >&2
    for ((index = 0; index < ${#identity_hashes[@]}; index++)); do
        printf '  %s  %s\n' "${identity_hashes[index]}" "${identity_names[index]}" >&2
    done
    exit 1
fi
signing_identity="${identity_hashes[0]}"
printf 'Application signing: %s\n' "${identity_names[0]}"
"$repo_root/scripts/build.sh" "$configuration"
source_app="$repo_root/.build/xcode/Build/Products/$configuration/SI.app"
mkdir -p "$(dirname "$destination")"
staging="$(mktemp -d "$(dirname "$destination")/.si-install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto "$source_app" "$staging/SI.app"
# Xcode may emit a separate Debug dylib. Sign nested code before the app bundle.
for library in "$staging/SI.app/Contents/MacOS/"*.dylib; do
    if [[ -f "$library" ]]; then
        /usr/bin/codesign --force --sign "$signing_identity" --timestamp=none "$library"
    fi
done
# Re-sign Sparkle from the inside out with the selected app identity.
sparkle="$staging/SI.app/Contents/Frameworks/Sparkle.framework"
for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" \
    "$sparkle/Versions/B/XPCServices/Downloader.xpc" "$sparkle/Versions/B/Autoupdate" \
    "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    /usr/bin/codesign --force --sign "$signing_identity" --timestamp=none --preserve-metadata=entitlements "$component"
done
/usr/bin/codesign --force --sign "$signing_identity" --timestamp=none "$staging/SI.app"
/usr/bin/codesign --verify --deep --strict "$staging/SI.app"
ensure_si_stopped
if [[ -e "$destination" ]]; then
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")"
    if [[ "$identifier" != 'com.caterm.inputmethod.si' && "$identifier" != 'com.caterm.si' ]]; then
        printf 'Refusing to replace an app with a different bundle identifier: %s\n' "$destination" >&2
        exit 1
    fi
    # Keep the old bundle only until replacement succeeds; the staging trap removes it.
    previous="$staging/Previous.app"
    mv "$destination" "$previous"
    if ! mv "$staging/SI.app" "$destination"; then
        if ! mv "$previous" "$destination"; then
            # Preserve the only remaining installed copy if rollback also fails.
            trap - EXIT
            printf 'Replacement and rollback failed. Recover the previous app from: %s\n' "$previous" >&2
        fi
        exit 1
    fi
else
    mv "$staging/SI.app" "$destination"
fi
printf 'Installed: %s\n' "$destination"
xcrun swift "$repo_root/scripts/register-input-source.swift" --register "$destination"
printf 'Add SI in System Settings > Keyboard > Text Input > Edit > + > English.\n'
printf 'If SI is not listed, reopen System Settings; log out and back in only if it is still missing.\n'
