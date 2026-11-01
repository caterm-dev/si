#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
si_llm_module llm.pinyin_to_text.predict --checkpoint "$si_llm_checkpoint" --input nihao --device "$si_llm_device" "$@"
