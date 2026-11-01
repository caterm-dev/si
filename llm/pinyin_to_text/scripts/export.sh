#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
si_llm_module llm.pinyin_to_text.export --checkpoint "$si_llm_checkpoint" --output "$si_llm_run/inference.pt" "$@"
