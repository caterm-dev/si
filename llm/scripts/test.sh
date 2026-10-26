#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
si_llm_baseline=false
for argument in "$@"; do
    case "$argument" in --baseline|--baseline=*) si_llm_baseline=true ;; esac
done
if ! "$si_llm_baseline"; then
    set -- --checkpoint "$si_llm_checkpoint" "$@"
fi
si_llm_module llm.test --config "$si_llm_config" --data "$si_llm_data" \
    --output "$si_llm_reports/test.json" --device "$si_llm_device" --threads "$si_llm_threads" "$@"
