#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
ri_bootstrap="${SI_RERANKER_SMALL_BOOTSTRAP_PYTHON:-python3.12}"
ri_pip_options=(--no-input)
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            printf '%s\n' 'Usage: setup.sh [--python PATH] [--venv PATH] [--offline] [--find-links PATH]' \
                'Install pinned PyTorch, NumPy and OpenCC in llm/.venv by default.' \
                'No corpus preparation or training is started. Relative paths use the repository root.'
            exit 0 ;;
        --python|--venv|--find-links)
            if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                printf 'Missing value for %s\n' "$1" >&2
                exit 2
            fi
            case "$1" in
                --python) ri_bootstrap="$2" ;;
                --venv) ri_venv="$2" ;;
                --find-links) ri_pip_options+=(--find-links "$2") ;;
            esac
            shift 2 ;;
        --offline) ri_pip_options+=(--no-index); shift ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
cd "$ri_repo"
case "$ri_venv" in /*) ;; *) ri_venv="$ri_repo/$ri_venv" ;; esac
if ! command -v "$ri_bootstrap" >/dev/null 2>&1; then
    printf 'Python 3.12 is required; select it with --python.\n' >&2
    exit 2
fi
"$ri_bootstrap" -c 'import sys; assert sys.version_info[:2] == (3, 12), "Python 3.12 is required"'
if [[ -e "$ri_venv" && ! -f "$ri_venv/pyvenv.cfg" ]]; then
    printf 'Refusing to modify a non-venv directory: %s\n' "$ri_venv" >&2
    exit 2
fi
if [[ ! -e "$ri_venv" ]]; then "$ri_bootstrap" -m venv "$ri_venv"; fi
ri_environment_python="$ri_venv/bin/python"
"$ri_environment_python" -c 'import sys; assert sys.version_info[:2] == (3, 12), "Existing environment must use Python 3.12"'
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$ri_workspace/.cache/pip}"
"$ri_environment_python" -m pip --disable-pip-version-check install "${ri_pip_options[@]}" -r "$ri_root/requirements.txt"
"$ri_environment_python" -m pip --disable-pip-version-check check
"$ri_environment_python" - <<'PY'
import importlib.metadata
import torch
from opencc import OpenCC
for name, expected in [('torch', '2.6.0'), ('numpy', '2.2.6'), ('opencc-python-reimplemented', '0.1.7')]:
    assert importlib.metadata.version(name).split('+')[0] == expected, name
assert OpenCC('t2s').convert('中文測試') == '中文测试'
print('Small-reranker environment ready; MPS:', torch.backends.mps.is_available())
PY
