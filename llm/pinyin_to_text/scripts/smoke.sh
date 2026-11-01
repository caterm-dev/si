#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
if [[ $# -eq 0 ]]; then
    set -- --output "llm/pinyin_to_text/runs/smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
si_llm_module llm.pinyin_to_text.csv_data.smoke --csv-root "$si_llm_csv" "$@"
