#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
ri_module llm.reranker_small.prepare --config "$ri_config" --output "$ri_data" "$@"
