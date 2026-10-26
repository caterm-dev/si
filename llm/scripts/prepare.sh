#!/bin/bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
for argument in "$@"; do
    case "$argument" in
        --sources|--sources=*) si_llm_module llm.prepare "$@" ;;
    esac
done
si_llm_module llm.csv_data.prepare "$@"
