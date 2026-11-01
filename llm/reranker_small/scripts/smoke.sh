#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
if [[ $# -eq 0 ]]; then
    set -- --output "$ri_root/runs/smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
ri_module llm.reranker_small.smoke "$@"
