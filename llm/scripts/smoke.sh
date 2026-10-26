#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
if [[ $# -eq 0 ]]; then
    set -- --output "llm/runs/smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
si_llm_module llm.csv_data.smoke "$@"
