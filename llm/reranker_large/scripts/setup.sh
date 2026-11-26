#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
rl_bootstrap="${SI_RERANKER_LARGE_BOOTSTRAP_PYTHON:-python3.12}"
rl_requirements="$rl_root/requirements.txt"
rl_pip_options=(--no-input)
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            printf '%s\n' 'Usage: setup.sh [--teacher] [--python PATH] [--venv PATH] [--offline] [--find-links PATH]' \
                'Install pinned student dependencies; --teacher adds the local Qwen adapter dependencies.' \
                'No model download, corpus preparation or training. Default environment: llm/.venv.'
            exit 0 ;;
        --teacher) rl_requirements="$rl_root/requirements-teacher.txt"; shift ;;
        --offline) rl_pip_options+=(--no-index); shift ;;
        --python|--venv|--find-links)
            if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                printf 'Missing value for %s\n' "$1" >&2; exit 2
            fi
            case "$1" in
                --python) rl_bootstrap="$2" ;;
                --venv) rl_venv="$2" ;;
                --find-links) rl_pip_options+=(--find-links "$2") ;;
            esac
            shift 2 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
cd "$rl_repo"
case "$rl_venv" in /*) ;; *) rl_venv="$rl_repo/$rl_venv" ;; esac
"$rl_bootstrap" -c 'import sys; assert sys.version_info[:2] == (3, 12), "Python 3.12 required"'
if [[ -e "$rl_venv" && ! -f "$rl_venv/pyvenv.cfg" ]]; then
    printf 'Refusing a non-venv directory: %s\n' "$rl_venv" >&2; exit 2
fi
if [[ ! -e "$rl_venv" ]]; then "$rl_bootstrap" -m venv "$rl_venv"; fi
"$rl_venv/bin/python" -c 'import sys; assert sys.version_info[:2] == (3, 12), "Python 3.12 required"'
"$rl_venv/bin/python" -m pip --disable-pip-version-check install "${rl_pip_options[@]}" -r "$rl_requirements"
"$rl_venv/bin/python" -m pip --disable-pip-version-check check
