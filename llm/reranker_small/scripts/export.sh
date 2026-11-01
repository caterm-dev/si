#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
ri_module llm.reranker_small.export --checkpoint "$ri_checkpoint" --data "$ri_data" --output "$ri_export" "$@"
