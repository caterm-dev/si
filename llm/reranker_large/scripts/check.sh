#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
cd "$rl_repo"
exec "${SI_RERANKER_LARGE_PYTHON:-$rl_venv/bin/python}" -m unittest discover -s llm/reranker_large/tests -v "$@"
