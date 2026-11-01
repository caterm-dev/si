#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
ri_module llm.reranker_small.benchmarks.evaluate --checkpoint "$ri_checkpoint" \
    --output "$ri_reports/chinese-v1-test.json" --device "$ri_device" --threads "$ri_threads" "$@"
