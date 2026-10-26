#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
    cat <<'HELP'
Usage: setup.sh [options]

Create/reuse an isolated Python 3.12 environment and install pinned training tools.
No model training or data download is started.

  --python PATH             Bootstrap Python (default: python3.12, then python3)
  --venv PATH               Environment directory (default: llm/.venv)
  --torch-index-url URL     Optional PyTorch wheel index for a chosen CUDA build
  --offline                 Install from already available local wheels only
  --find-links PATH         Additional wheel directory (repeatable)
  -h, --help                Show this help without creating an environment

Relative paths are resolved from the repository root. SI_LLM_VENV sets the default
environment directory; SI_LLM_BOOTSTRAP_PYTHON sets the bootstrap interpreter.
HELP
}

si_llm_bootstrap="${SI_LLM_BOOTSTRAP_PYTHON:-}"
si_llm_torch_index=""
si_llm_pip_options=(--no-input)
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --python|--venv|--torch-index-url|--find-links)
            if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                printf 'Missing value for %s\n' "$1" >&2
                exit 2
            fi
            case "$1" in
                --python) si_llm_bootstrap="$2" ;;
                --venv) si_llm_venv="$2" ;;
                --torch-index-url) si_llm_torch_index="$2" ;;
                --find-links) si_llm_pip_options+=(--find-links "$2") ;;
            esac
            shift 2
            ;;
        --offline) si_llm_pip_options+=(--no-index); shift ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

cd "$si_llm_repo"
case "$si_llm_venv" in
    /*) ;;
    *) si_llm_venv="$si_llm_repo/$si_llm_venv" ;;
esac
if [[ -z "$si_llm_bootstrap" ]]; then
    if command -v python3.12 >/dev/null 2>&1; then
        si_llm_bootstrap="python3.12"
    else
        si_llm_bootstrap="python3"
    fi
fi
if ! command -v "$si_llm_bootstrap" >/dev/null 2>&1; then
    printf 'Python 3.12 was not found. Set --python /path/to/python3.12.\n' >&2
    exit 2
fi
"$si_llm_bootstrap" -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 12) else "Python 3.12 is required; select it with --python.")'

if [[ -e "$si_llm_venv" && ! -f "$si_llm_venv/pyvenv.cfg" ]]; then
    printf 'Refusing to modify an existing directory that is not a virtual environment: %s\n' "$si_llm_venv" >&2
    exit 2
fi
if [[ ! -e "$si_llm_venv" ]]; then
    "$si_llm_bootstrap" -m venv "$si_llm_venv"
fi
si_llm_environment_python="$si_llm_venv/bin/python"
if [[ ! -x "$si_llm_environment_python" ]]; then
    printf 'Virtual environment is incomplete: %s\nChoose a new --venv directory.\n' "$si_llm_venv" >&2
    exit 2
fi
"$si_llm_environment_python" -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 12) else "Existing environment must use Python 3.12; choose a new --venv directory.")'

export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$si_llm_root/.cache/pip}"
if [[ -n "$si_llm_torch_index" ]]; then
    "$si_llm_environment_python" -m pip --disable-pip-version-check install \
        "${si_llm_pip_options[@]}" --force-reinstall --index-url "$si_llm_torch_index" 'torch==2.6.0'
fi
"$si_llm_environment_python" -m pip --disable-pip-version-check install \
    "${si_llm_pip_options[@]}" --requirement "$si_llm_root/requirements.txt"
"$si_llm_environment_python" -m pip --disable-pip-version-check check
"$si_llm_environment_python" - <<'PY'
import importlib.metadata
import sys
import torch
import pypinyin
import numpy

for package, expected in (("torch", "2.6.0"), ("pypinyin", "0.55.0"), ("numpy", "2.2.6")):
    actual = importlib.metadata.version(package)
    if actual.split("+")[0] != expected:
        raise SystemExit(f"Expected {package} {expected}, got {actual}")
print(f"Environment ready: {sys.executable}")
print(f"PyTorch {torch.__version__}; pypinyin {pypinyin.__version__}")
print(f"NumPy {numpy.__version__}; tensor conversion: {torch.from_numpy(numpy.zeros(1)).tolist()}")
print(f"CUDA available: {torch.cuda.is_available()}; MPS available: {torch.backends.mps.is_available()}")
PY
printf 'Setup complete. Run %s/scripts/check.sh or %s/scripts/smoke.sh.\n' "$si_llm_root" "$si_llm_root"
