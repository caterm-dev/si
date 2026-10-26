#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
si_llm_module llm.train --config "$si_llm_config" --data "$si_llm_data" --run "$si_llm_run" \
    --device "$si_llm_device" --threads "$si_llm_threads" "$@"
