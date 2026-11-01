#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
ri_module llm.reranker_small.evaluate --checkpoint "$ri_checkpoint" --data "$ri_data" --split test --output "$ri_reports/test.json" --device "$ri_device" --threads "$ri_threads" "$@"
