#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
ri_module llm.reranker_small.rank --checkpoint "$ri_checkpoint" --device "$ri_device" --threads "$ri_threads" "$@"
