#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
cd "$rl_repo"
export PYTHONUNBUFFERED=1
exec "${SI_RERANKER_LARGE_PYTHON:-$rl_venv/bin/python}" \
  "$rl_root/scripts/prepare_sequence_kd.py" "$@"
