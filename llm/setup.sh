#!/bin/bash
set -euo pipefail
llm_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$llm_root"
python_bin="${PYTHON:-python3}"
"$python_bin" - <<'PY'
import platform
import sys

if sys.version_info < (3, 11):
    raise SystemExit("Use Python 3.11 or later (3.12 recommended).")
if platform.system() != "Darwin" or platform.machine() != "arm64":
    raise SystemExit("MLX setup requires native Apple Silicon macOS Python.")
PY
if [[ ! -d .venv ]]; then
    "$python_bin" -m venv .venv
fi
if command -v uv >/dev/null 2>&1; then
    UV_CACHE_DIR="$llm_root/.cache/uv" uv pip install \
        --python "$llm_root/.venv/bin/python" -r requirements.lock.txt
else
    PIP_CACHE_DIR="$llm_root/.cache/pip" .venv/bin/python -m pip install -r requirements.lock.txt
fi
.venv/bin/python prepare.py
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/python experiment.py doctor
printf '\nEnvironment ready. See llm/README.md for local model paths and commands.\n'
