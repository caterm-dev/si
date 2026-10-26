#!/bin/bash
# Shared by the executable entry points; source this file rather than running it.
set -euo pipefail

si_llm_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
si_llm_repo="$(cd "$si_llm_root/.." && pwd)"
si_llm_venv="${SI_LLM_VENV:-$si_llm_root/.venv}"
case "$si_llm_venv" in
    /*) ;;
    *) si_llm_venv="$si_llm_repo/$si_llm_venv" ;;
esac
source "$si_llm_root/scripts/defaults.sh"

si_llm_python() {
    local interpreter="${SI_LLM_PYTHON:-$si_llm_venv/bin/python}"
    cd "$si_llm_repo"
    if ! command -v "$interpreter" >/dev/null 2>&1; then
        printf 'Python environment unavailable: %s\nRun %s/scripts/setup.sh first, or set SI_LLM_PYTHON to an existing interpreter.\n' \
            "$interpreter" "$si_llm_root" >&2
        exit 2
    fi
    export PYTHONUNBUFFERED=1
    exec "$interpreter" "$@"
}

si_llm_module() {
    local module="$1"
    shift
    si_llm_python -m "$module" "$@"
}
