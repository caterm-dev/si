#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
si_llm_module llm.train --config "$si_llm_root/configs/0.4b-static-csv.json" "$@"
