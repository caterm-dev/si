#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
export PYTHONPATH="$ri_repo/.build/coreml-tools${PYTHONPATH:+:$PYTHONPATH}"
ri_module llm.reranker_small.coreml_export --checkpoint "$ri_checkpoint" --data "$ri_data" \
    --output "$ri_repo/mac/SI/Core/Resources/Reranker" "$@"
