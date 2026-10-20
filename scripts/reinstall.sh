#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-Release}"
if [[ $# -gt 1 ]]; then
    printf 'Usage: %s [Debug|Release]\n' "$0" >&2
    exit 2
fi
case "$configuration" in
    Debug|Release) ;;
    -h|--help) printf 'Usage: %s [Debug|Release]\n' "$0"; exit 0 ;;
    *) printf 'Usage: %s [Debug|Release]\n' "$0" >&2; exit 2 ;;
esac

user_id="$(id -u)"
si_is_running() {
    local status=0
    pgrep -u "$user_id" -x SI >/dev/null || status=$?
    case "$status" in
        0) return 0 ;;
        1) return 1 ;;
        *)
            printf 'Cannot check whether SI is running; reinstall cancelled.\n' >&2
            exit 1
            ;;
    esac
}

signal_si() {
    local status=0
    pkill "-$1" -u "$user_id" -x SI || status=$?
    # No match is harmless if SI exited between the check and the signal.
    if [[ "$status" -gt 1 ]]; then
        printf 'Cannot stop SI; reinstall cancelled.\n' >&2
        exit 1
    fi
}

wait_for_si_exit() {
    local attempt
    for ((attempt = 0; attempt < 50; attempt++)); do
        if ! si_is_running; then
            return 0
        fi
        sleep 0.1
    done
    ! si_is_running
}

if si_is_running; then
    printf 'Stopping SI for the current user. Pending composition or unsaved learning may be lost.\n'
    signal_si TERM
    if ! wait_for_si_exit; then
        printf 'SI did not exit within five seconds; sending SIGKILL.\n' >&2
        signal_si KILL
        if ! wait_for_si_exit; then
            printf 'SI is still running or restarting. Select another input source and stop any Xcode run before retrying.\n' >&2
            exit 1
        fi
    fi
fi

# Keep the installer's process checks, signing, backup, rollback and registration.
exec "$repo_root/scripts/install.sh" "$configuration"
