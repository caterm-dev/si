#!/bin/bash
# Small-reranker entry points; paths are independent of converter environment overrides.
set -euo pipefail
ri_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ri_workspace="$(cd "$ri_root/.." && pwd)"
ri_repo="$(cd "$ri_workspace/.." && pwd)"
ri_venv="${SI_RERANKER_SMALL_VENV:-$ri_workspace/.venv}"
case "$ri_venv" in /*) ;; *) ri_venv="$ri_repo/$ri_venv" ;; esac
source "$ri_root/scripts/defaults.sh"
ri_module() {
    local module="$1"
    shift
    local interpreter="${SI_RERANKER_SMALL_PYTHON:-$ri_venv/bin/python}"
    cd "$ri_repo"
    if ! command -v "$interpreter" >/dev/null 2>&1; then
        printf 'Python environment unavailable: %s\nRun %s/scripts/setup.sh first.\n' "$interpreter" "$ri_root" >&2
        exit 2
    fi
    export PYTHONUNBUFFERED=1
    exec "$interpreter" -m "$module" "$@"
}
