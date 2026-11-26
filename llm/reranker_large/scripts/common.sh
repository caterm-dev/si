#!/bin/bash
set -euo pipefail
rl_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
rl_repo="$(cd "$rl_root/../.." && pwd)"
rl_venv="${SI_RERANKER_LARGE_VENV:-$rl_repo/llm/.venv}"
case "$rl_venv" in /*) ;; *) rl_venv="$rl_repo/$rl_venv" ;; esac
rl_module() {
    local interpreter="${SI_RERANKER_LARGE_PYTHON:-$rl_venv/bin/python}"
    if [[ "${1:-}" == teacher && -n "${SI_RERANKER_LARGE_TEACHER_PYTHON:-}" ]]; then
        interpreter="$SI_RERANKER_LARGE_TEACHER_PYTHON"
    fi
    cd "$rl_repo"
    export PYTHONUNBUFFERED=1
    exec "$interpreter" -m llm.reranker_large.cli "$@"
}
