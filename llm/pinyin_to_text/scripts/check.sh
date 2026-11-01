#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
si_llm_python -m unittest discover -s llm/pinyin_to_text/tests -v "$@"
