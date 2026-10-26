#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
si_llm_module llm.csv_data.prepare --config "$si_llm_config" --csv-root "$si_llm_csv" --output "$si_llm_data" "$@"
