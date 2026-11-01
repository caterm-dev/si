#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
ri_module llm.reranker_small.train --resume --config "$ri_config" --data "$ri_data" --run "$ri_run" --device "$ri_device" --threads "$ri_threads" "$@"
