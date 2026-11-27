#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
interpreter="${SI_RERANKER_LARGE_PYTHON:-$rl_venv/bin/python}"
cd "$rl_repo"
export PYTHONUNBUFFERED=1
exec "$interpreter" "$rl_root/scripts/continue_pretrain.py" "$@"
